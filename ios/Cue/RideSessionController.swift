// Intent: The ride-screen shell's engine room (RFC 0003, FR-001…009):
//         owns the region cache, one RideEngine + CueDispatcher per ride,
//         the CoreLocation feed, both marker inputs (voice intent and
//         watch button), the after-ride review pass (D7, FR-008), and
//         end-of-ride export of the policy trace plus the D4 latency
//         sidecar. Grades land in the trace BEFORE export — stopping a
//         ride enters .reviewing; export happens in finishReview(). Every
//         HEAD_UP also plays CueChimePlayer's phone-local chime alongside
//         the watch dispatch — an independent delivery path, not gated on
//         watch reachability.
// Context: Rides sample in the background (the location background mode
//          is declared in ios/CueSupport/Info.plist and enabled for the
//          ride's duration only); a build without the merged plist
//          degrades to foreground-only and the ride screen says so. GPS
//          retention in traces follows the per-ride debug toggle
//          (NFR-005).
import CoreLocation
import CueKernel
import CueMapImport
import CueRideEngine
import CuePicoLink
import CueWatchLink
import Foundation

@MainActor
final class RideSessionController: NSObject, ObservableObject {
    static let shared = RideSessionController()

    enum State: Equatable {
        case noRegion
        case ready
        case riding
        /// Between riding and ready: location is stopped but the engine's
        /// recorder stays alive so grades write into the trace before
        /// export (D7 — reviews[] must be in the file, not a sidecar).
        case reviewing
    }

    @Published private(set) var state: State = .noRegion
    @Published private(set) var segmentCount = 0
    @Published private(set) var zoneCount = 0
    @Published private(set) var cueCount = 0
    @Published private(set) var markerCount = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastReasonCode: UInt8?
    @Published private(set) var lastError: String?
    @Published private(set) var exportedFiles: [URL] = []
    @Published var debugGPS = false
    /// HEAD_UP cues of the ride under review, chronological (D7 rows).
    @Published private(set) var reviewCues: [(tMs: UInt32, eventID: UInt32)] = []
    @Published private(set) var reviewMarkers: [(tMs: UInt32, segmentID: UInt32)] = []
    /// Current grade per event id, so the review buttons show selection.
    @Published private(set) var grades: [UInt32: ReviewOutcome] = [:]

    private var segments: [RoadSegment] = []
    private var zones: [SqueezeZone] = []
    private var engine: RideEngine?
    private var dispatcher: CueDispatcher?
    /// The MCU cue channel (RFC 0006). Owned for the app's lifetime, not
    /// per ride, so the link can be up before a ride starts and survive
    /// the gaps between them.
    let picoLink = PicoBLELink()
    /// The presenters a HEAD_UP fans out to. The Pico is deliberately
    /// absent: it self-actuates from its own kernel on the step stream
    /// (RFC 0006 D2), so presenting to it here would double-cue.
    private var presenters: [CuePresenter] = []
    private var rideStartEpochMs: UInt64 = 0
    private var rideID = ""
    private let locationManager = CLLocationManager()
    /// One instance for the app's lifetime, injected into every RideEngine
    /// (RFC 0002) — reviews/markers from past rides bias live cueing on the
    /// next one. Loaded once at init; persisted after every mutation.
    private let personalMemoryStore: PersonalMemoryStore
    @Published private(set) var rememberedSegmentCount = 0

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("region-cache")
    }

    // static: needed before super.init() (personalMemoryStore is set in
    // phase 1 of init, before `self`/instance computed properties are
    // available), and reused by the instance property below.
    private static var personalMemoryDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("personal-memory")
    }

    private var personalMemoryDirectory: URL { Self.personalMemoryDirectoryURL }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    override private init() {
        personalMemoryStore = PersonalMemoryStore.load(from: Self.personalMemoryDirectoryURL)
        super.init()
        rememberedSegmentCount = personalMemoryStore.recordCount
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        loadCachedRegion()
        // Watch markers arrive through the same session the cue path uses.
        PhoneWatchLink.shared.onMarker = { [weak self] payload in
            Task { @MainActor in self?.markFromWatch(payload) }
        }
    }

    /// Persist the store and refresh the published count — called after
    /// every mutation (grading, marking, custom-zone import). A save
    /// failure is surfaced but not fatal: the in-memory store stays
    /// correct for the rest of the session either way.
    private func persistPersonalMemory() {
        rememberedSegmentCount = personalMemoryStore.recordCount
        do {
            try personalMemoryStore.save(to: personalMemoryDirectory)
        } catch {
            lastError = "personal memory save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Region (D1a cache)

    func loadCachedRegion() {
        do {
            guard let (_, cached) = try SegmentStore.load(from: cacheDirectory) else {
                state = .noRegion
                return
            }
            adopt(segments: cached)
        } catch {
            state = .noRegion
            lastError = "region cache unreadable: \(error.localizedDescription)"
        }
    }

    /// Import an Overpass `out geom;` JSON file (the same shape the desk
    /// tools consume — D1a); parses, caches, and scores it.
    func importRegion(from url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let extract = try OverpassExtract(data: data)
            let imported = try SegmentImporter.deriveSegments(from: extract)
            try SegmentStore.save(imported,
                                  sourceSHA256: SegmentStore.sha256Hex(of: data),
                                  to: cacheDirectory)
            adopt(segments: imported)
            lastError = nil
        } catch {
            lastError = "import failed: \(error.localizedDescription)"
        }
    }

    /// Import webmap.dev's "Custom squeeze zones" GeoJSON export (rider-
    /// drawn zones — no OSM tags, so no severity/confidence to score):
    /// snap each zone's geometry to the currently-imported region's
    /// segments and record an "unsafe here" contribution for each matched
    /// segment (RFC 0002 — a custom zone is the same epistemic category as
    /// an in-ride marker, just authored beforehand). Requires a region to
    /// already be imported (segments are the snap target); unmatched zones
    /// are surfaced via lastError, not silently dropped. Re-importing the
    /// same export is harmless — D2's derivation is a marker_count > 0
    /// check, not graduated, so a repeat import cannot change the outcome.
    func importCustomZones(from url: URL) {
        // Reading the file, parsing GeoJSON, and matchSegments (O(vertices
        // x segment-edges), brute-force, acceptable at region scale but
        // plausibly hundreds of ms for a large region or dense zone file)
        // all run off the main actor (Task.detached, not a plain Task —
        // RideSessionController is @MainActor, and a non-detached Task
        // would inherit that isolation), so a big import never freezes the
        // UI. URL is Sendable and its security-scoped access calls are
        // documented as safe off the main thread; CustomZoneFeature/
        // RoadSegment/CustomZoneMatchResult are all Sendable value types.
        let currentSegments = segments
        Task.detached { [weak self] in
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let features = try CustomZoneImport.parseFeatures(from: data)
                let result = CustomZoneImport.matchSegments(for: features, segments: currentSegments)
                await MainActor.run { self?.applyCustomZoneMatchResult(result) }
            } catch {
                await MainActor.run {
                    self?.lastError = "custom zone import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Applies a background-computed match result: records each matched
    /// segment as unsafe, persists, and surfaces both unmatched-zone and
    /// store-eviction visibility (RFC 0002 D7 — "a bound is not a silent
    /// truncation") in one message. Diffs evictionCount rather than
    /// lastEvictedSegmentID: this is a BATCH of writes (every matched
    /// segment across every zone in the file), and a single before/after
    /// ID comparison would only ever see the last of possibly several
    /// evictions the batch caused.
    private func applyCustomZoneMatchResult(_ result: CustomZoneMatchResult) {
        let evictionsBefore = personalMemoryStore.evictionCount
        // REPLACES the imported-zone set, matching webmap.dev's own
        // import-replaces-everything contract: a segment the rider deleted a
        // zone from has to stop being flagged, and writing only the segments
        // the new file covers would leave it flagged forever. Directions are
        // unioned per segment across every zone in the file, so processing
        // order cannot decide the outcome (cue#30).
        personalMemoryStore.replaceUnsafeZones(directionsBySegment: result.directionsBySegment)
        persistPersonalMemory()
        var notes: [String] = []
        if !result.unmatchedZoneIDs.isEmpty {
            notes.append("\(result.unmatchedZoneIDs.count) custom zone(s) had no nearby "
                + "road segment and were skipped")
        }
        let evictedByThisImport = personalMemoryStore.evictionCount - evictionsBefore
        if evictedByThisImport > 0 {
            notes.append("personal memory store is full — \(evictedByThisImport) older "
                + "remembered segment\(evictedByThisImport == 1 ? "" : "s") forgotten to make room")
        }
        lastError = notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    private func adopt(segments imported: [RoadSegment]) {
        segments = imported
        zones = SqueezeScorer.scoreZones(from: imported)
        segmentCount = imported.count
        zoneCount = zones.count
        // Never yank an active ride OR an un-exported review to .ready —
        // flipping mid-review would silently drop the ungraded trace.
        if state != .riding && state != .reviewing { state = .ready }
    }

    // MARK: - Ride lifecycle

    /// Set while waiting for the user's answer to the first-launch
    /// permission dialog; the ride actually starts (or aborts) in
    /// locationManagerDidChangeAuthorization.
    private var awaitingAuthorization = false

    func startRide() {
        guard state == .ready else { return }
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginRide()
        case .notDetermined:
            // Asynchronous: the dialog returns immediately — do NOT flip
            // to .riding until the user actually answers.
            awaitingAuthorization = true
            locationManager.requestWhenInUseAuthorization()
        default:
            lastError = "location permission denied — enable it in Settings to ride"
        }
    }

    private func beginRide() {
        // ONE Date() read: startedAt and rideStartEpochMs must name the
        // same instant, or a marker pressed in the first millisecond can
        // be rejected as pre-ride.
        let start = Date()
        let startedAt = Self.iso8601.string(from: start)
        // startedAt keeps the schema's ISO 8601 form; the ride id doubles
        // as a filename stem, so its colons become dashes (FAT32/AirDrop
        // portability).
        rideID = "ride-" + startedAt.replacingOccurrences(of: ":", with: "-")
        rideStartEpochMs = UInt64(start.timeIntervalSince1970 * 1000)
        engine = RideEngine(segments: segments, zones: zones,
                            personalMemoryStore: personalMemoryStore,
                            rideID: rideID, startedAt: startedAt,
                            debugGPS: debugGPS)
        dispatcher = CueDispatcher(transport: PhoneWatchLink.shared,
                                   rideStartEpochMs: rideStartEpochMs)
        presenters = [WatchCuePresenter(dispatcher: dispatcher!),
                      ChimeCuePresenter()]
        CueChimePlayer.shared.prepareForRide()
        // The Pico runs the same kernel on the steps we stream it and
        // actuates its own decisions; the phone keeps stepping as the
        // shadow, which it must do anyway to produce the trace (D2).
        picoLink.beginRide(config: CuePolicy.defaultConfig())
        engine?.onStep = { [weak self] context in
            self?.picoLink.send(step: context)
        }
        cueCount = 0
        markerCount = 0
        sampleCount = 0
        lastReasonCode = nil
        exportedFiles = []
        // Ride sampling must survive screen lock: the first field trace
        // stopped at 37 s when the phone was pocketed (#87). Guarded on
        // the declared capability — setting allowsBackgroundLocationUpdates
        // without the background mode is a runtime crash, and a build
        // without the merged Info.plist should degrade to foreground-only,
        // not die.
        if Self.hasLocationBackgroundMode {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        // Auto-pausing ends background delivery for good when the rider
        // stops at a light; a ride is over when the rider says so.
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()
        state = .riding
    }

    /// True when the app declares the `location` background mode (the
    /// merged Info.plist). Read once — the bundle cannot change mid-run.
    private static let hasLocationBackgroundMode: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
            as? [String])?.contains("location") == true

    /// UI-facing alias: whether rides survive screen lock in this build.
    static var ridesInBackground: Bool { hasLocationBackgroundMode }

    /// Stop sampling and enter the review pass (D7). Deliberately does NOT
    /// export: grades must land in the trace first, so export waits for
    /// finishReview(). The engine and dispatcher stay alive for grading —
    /// and for queued watch markers still in flight (D5). Also tells the
    /// watch the ride ended so "Ride mode" doesn't sit ON over a dead ride.
    func stopRide() {
        guard state == .riding, let engine else { return }
        locationManager.stopUpdatingLocation()
        if Self.hasLocationBackgroundMode {
            // Drop the background privilege (and its status-bar indicator)
            // the moment the ride ends — NFR-005's spirit applies to
            // sampling time, not just storage.
            locationManager.allowsBackgroundLocationUpdates = false
        }
        CueChimePlayer.shared.teardown()
        // Close the Pico session but keep the link: the sidecar is
        // exported in finishReview(), after grades land, so the streamer's
        // records must outlive stopRide().
        picoLink.endRide()
        engine.onStep = nil
        presenters = []
        PhoneWatchLink.shared.sendRideEnded()
        reviewCues = engine.recorder.cueSummaries
        reviewMarkers = engine.recorder.markerSummaries
        grades = [:]
        state = .reviewing
    }

    // MARK: - After-ride review (D7, FR-008)

    /// Grade one cue. Re-grading replaces (one review per cue). Routes
    /// through engine.recordReview (not recorder.addReview directly) so the
    /// outcome also feeds personal route memory (RFC 0002 D1) — the
    /// segment this event was observed on THIS ride joins the review to
    /// the shared store, biasing a future ride.
    func grade(eventID: UInt32, outcome: ReviewOutcome) {
        guard state == .reviewing, let engine else { return }
        engine.recordReview(eventID: eventID, outcome: outcome,
                            reviewedAt: nowISO8601())
        grades[eventID] = outcome
        persistPersonalMemory()
    }

    /// Export everything and return to ready. Grading nothing is valid —
    /// an empty reviews[] still satisfies the schema.
    func finishReview() {
        guard state == .reviewing else { return }
        // This is the ONLY exit from .reviewing: the defer guarantees the
        // rider is never stranded in a state whose one button silently
        // does nothing, no matter what the guards below decide.
        defer {
            self.engine = nil
            self.dispatcher = nil
            reviewCues = []
            reviewMarkers = []
            grades = [:]
            state = .ready
        }
        guard let engine, let dispatcher else {
            lastError = "review session lost — nothing to export"
            return
        }
        // Publish each artifact AS it lands: if a later write throws, the
        // files already on disk stay visible instead of being orphaned.
        exportedFiles = []
        lastError = nil
        do {
            let traceURL = documentsDirectory
                .appendingPathComponent("\(rideID)-trace.json")
            try engine.recorder.exportPolicyTrace().write(to: traceURL)
            exportedFiles.append(traceURL)
            let latencyURL = documentsDirectory
                .appendingPathComponent("\(rideID)-latency.json")
            try dispatcher.exportLatencyLog(rideID: rideID).write(to: latencyURL)
            exportedFiles.append(latencyURL)
            // The MCU channel's per-ride evidence (RFC 0006 D5): shadow
            // vs on-target decisions, divergences, and which HEAD_UPs the
            // Pico actually actuated. Absent when no ride streamed.
            if let picoSidecar = try picoLink.exportSidecar() {
                let picoURL = documentsDirectory
                    .appendingPathComponent("\(rideID)-pico.json")
                try picoSidecar.write(to: picoURL)
                exportedFiles.append(picoURL)
            }
            if debugGPS {
                let debugURL = documentsDirectory
                    .appendingPathComponent("\(rideID)-trace-debug.json")
                try engine.recorder.exportDebugTrace().write(to: debugURL)
                exportedFiles.append(debugURL)
            }
        } catch {
            lastError = "export failed: \(error.localizedDescription)"
        }
    }

    /// Discard the ride under review (#135): tear the session down exactly
    /// as finishReview() does but export NOTHING — no trace, no latency
    /// sidecar, no debug file — and reverse every personal-memory
    /// contribution this ride made. Grades AND "unsafe here" marks are
    /// rolled back: the marker was part of the ride being discarded, so
    /// its evidence goes with it (NFR-005 / RFC 0002). Marks were already
    /// persisted mid-ride, so the rollback is persisted too. Irreversible
    /// — the UI must confirm before calling.
    func discardReview() {
        guard state == .reviewing else { return }
        // Same defer discipline as finishReview: the rider always lands
        // back in .ready with the session torn down, whatever happens.
        defer {
            engine = nil
            dispatcher = nil
            reviewCues = []
            reviewMarkers = []
            grades = [:]
            state = .ready
        }
        engine?.undoPersonalMemoryContributions()
        persistPersonalMemory()
    }

    /// Review timestamps use the same caller-formatted ISO 8601 UTC
    /// convention as startedAt (deterministic under test).
    private func nowISO8601() -> String {
        Self.iso8601.string(from: Date())
    }

    /// One formatter for the class: ISO8601DateFormatter is costly to
    /// instantiate and this is on the per-grade-tap path. Isolation:
    /// the class is @MainActor, so the static is MainActor-confined.
    private static let iso8601 = ISO8601DateFormatter()

    // MARK: - Markers (both inputs, one record shape — D5)

    /// The voice App Intent and the phone UI land here. Riding only: a
    /// "now" mark during the review pass would anchor to the ride's LAST
    /// sample — not where the rider is — so it is rejected.
    @discardableResult
    func mark() -> Bool {
        guard state == .riding, let engine, engine.mark() else { return false }
        markerCount += 1
        // engine.mark() already fed personal route memory (RFC 0002); flush
        // it to disk and refresh the published count.
        persistPersonalMemory()
        return true
    }

    /// The watch button lands here; the payload's press instant maps back
    /// to ride time so queued late deliveries anchor correctly (D5).
    /// Deliberately NOT gated on .riding: a queued press that arrives
    /// during the review pass was made mid-ride and still belongs in the
    /// trace (the engine stays alive until finishReview).
    private func markFromWatch(_ payload: MarkerPayload) {
        guard let engine, payload.markedTsMs >= rideStartEpochMs else { return }
        let tMs = UInt32(min(UInt64(UInt32.max),
                             payload.markedTsMs - rideStartEpochMs))
        if engine.mark(atTMs: tMs) {
            markerCount += 1
            persistPersonalMemory()
            // A queued press landing mid-review must also appear in the
            // review list, not just the trace — refresh the snapshot.
            if state == .reviewing {
                reviewMarkers = engine.recorder.markerSummaries
            }
        }
    }

    private func process(_ location: CLLocation) {
        guard state == .riding, let engine, dispatcher != nil else { return }
        let epochMs = UInt64(location.timestamp.timeIntervalSince1970 * 1000)
        guard epochMs >= rideStartEpochMs else { return }
        let tMs = UInt32(min(UInt64(UInt32.max), epochMs - rideStartEpochMs))
        let fix = RideFix(
            tMs: tMs,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            speedMps: max(0, location.speed),  // negative = invalid (CL contract)
            headingDeg: location.course >= 0 ? location.course : nil)
        guard let decision = engine.process(fix) else { return }
        sampleCount += 1
        lastReasonCode = decision.reason_code
        if decision.isHeadUp {
            cueCount += 1
            deliver(decision, sampleTMs: tMs)
        }
    }

    /// The cue-delivery boundary: every HEAD_UP that reaches the rider —
    /// kernel-decided or debug-synthetic (#131) — leaves through here, so
    /// no two delivery channels can diverge between the two paths.
    ///
    /// The dispatcher is no longer threaded through: each presenter now
    /// captures whatever it needs, so the old "pass it in so no call site
    /// can hold a nil" argument is carried by the presenter list itself.
    private func deliver(_ decision: CueDecision, sampleTMs tMs: UInt32) {
        for presenter in presenters {
            presenter.present(decision, sampleTMs: tMs)
        }
    }

    #if DEBUG
    // MARK: - Debug test cue (#131)

    /// Synthetic test-cue event ids live in this reserved range so the
    /// latency-sidecar rows a test tap produces are explicitly marked as
    /// test artifacts. Real event ids are content-derived over the whole
    /// UInt32 space, so a collision is possible but vanishingly rare; its
    /// worst case is the watch gate deduping ONE real cue's haptic — the
    /// phone chime and the kernel's own one-cue-per-event rule (FR-004)
    /// are unaffected, and NFR-001 prefers a missed tap over a wrong one.
    private static let testCueEventIDBase: UInt32 = 0xFFFF_0000
    /// Distinct id per tap: the watch expiry gate dedups by event_id, and
    /// a reused id would silently swallow every tap after the first.
    private var testCueTapCount: UInt32 = 0

    /// Debug builds only (#131): fire a synthetic HEAD_UP through the same
    /// delivery boundary a kernel decision takes — phone chime plus watch
    /// dispatch — WITHOUT touching the engine. The trace, the review list,
    /// the cue counter, and personal memory never see it (NFR-003, NFR-005);
    /// the only durable evidence is the latency-sidecar row, marked by the
    /// reserved event-id range above.
    func fireTestCue() {
        guard state == .riding, dispatcher != nil else { return }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // max() guards a wall-clock adjustment mid-ride: a test cue
        // stamped at t=0 is harmless, a UInt64 underflow trap is not.
        let tMs = UInt32(min(UInt64(UInt32.max),
                             max(nowMs, rideStartEpochMs) - rideStartEpochMs))
        testCueTapCount += 1
        // 20 s expiry — the max_notice_s ceiling (spec §8 set 15; widened by
        // the §13 tuning loop) — so the watch gate still plays the cue over
        // a slow queued delivery.
        let decision = CueDecision.syntheticHeadUp(
            eventID: Self.testCueEventIDBase | (testCueTapCount & 0xFFFF),
            leadTimeS: 20)
        deliver(decision, sampleTMs: tMs)
    }
    #endif
}

extension RideSessionController: CLLocationManagerDelegate {
    // CLLocationManager delivers on the run loop it was started from —
    // the main run loop here — so assumeIsolated is sound.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for location in locations { process(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        MainActor.assumeIsolated {
            lastError = "location: \(error.localizedDescription)"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read outside the isolated closure: capturing the non-Sendable
        // manager inside it is a Swift 6 sendability error.
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard awaitingAuthorization else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                awaitingAuthorization = false
                beginRide()
            case .notDetermined:
                break  // dialog still pending; keep waiting
            default:
                awaitingAuthorization = false
                lastError = "location permission denied — enable it in Settings to ride"
            }
        }
    }
}
