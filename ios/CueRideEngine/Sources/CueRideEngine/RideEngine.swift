// Intent: The ride engine (RFC 0003 follow-up 5, FR-001…003, FR-009): one
//         1 Hz pipeline per ride — fix in, matched sample + observations
//         through cue_policy_step, everything recorded for schema-v1
//         export. The same kernel binary logic that runs here replays the
//         exported trace on a desk; divergence is a bug (NFR-003).
// Context: Platform-neutral by design — the app layer wraps CoreLocation
//          and feeds RideFix values, so `swift test` exercises the whole
//          pipeline on macOS and the D6 harness can drive it end to end.
// Pattern: Composition of the merged pieces: SegmentMatcher (D2),
//          RouteEventTracker (zone→RouteEvent), CuePolicy (D3 facade),
//          RideTraceRecorder (FR-009). The engine owns per-ride state;
//          create one per ride.
import CueKernel
import CueMapImport
import Foundation

/// One GPS fix as the app layer delivers it (CoreLocation vocabulary,
/// no CoreLocation dependency).
public struct RideFix {
    /// Milliseconds since ride start; must be strictly increasing — the
    /// replay schema requires it, so the engine drops violators.
    public let tMs: UInt32
    public let lat: Double
    public let lon: Double
    /// Ground speed, m/s; negative (CoreLocation "invalid") clamps to 0.
    public let speedMps: Double
    /// Course over ground [0, 360), or nil when unavailable.
    public let headingDeg: Double?

    public init(tMs: UInt32, lat: Double, lon: Double,
                speedMps: Double, headingDeg: Double?) {
        self.tMs = tMs
        self.lat = lat
        self.lon = lon
        self.speedMps = speedMps
        self.headingDeg = headingDeg
    }
}

/// Everything one kernel step consumed and produced, captured at the
/// single call site where all of it exists together (RFC 0006 D2).
///
/// The MCU link must feed the Pico byte-for-byte what the phone's own
/// kernel saw, or the shadow comparison would be checking two different
/// inputs and its divergences would be meaningless. Handing the caller
/// this bundle — rather than letting it re-derive the sample and events
/// from the fix — is what makes that guarantee structural.
public struct RideStepContext {
    public let sample: RideSample
    /// In tracker order, which is the order the kernel evaluated them
    /// (NFR-003 depends on this being stable).
    public let events: [RouteEvent]
    public let memory: PersonalMemory?
    public let decision: CueDecision
}

/// One ride's engine. Feed fixes in order; export the trace at ride end.
public final class RideEngine {
    /// Called after every kernel step that was not dropped, with the exact
    /// inputs and output of that step. Set by the app layer to stream the
    /// step to the Pico (RFC 0006 Phase B3); nil by default, so the engine
    /// behaves identically for callers that do not use the MCU link.
    public var onStep: ((RideStepContext) -> Void)?
    /// The most route events one kernel step may carry.
    ///
    /// The BLE wire caps a STEP at this many (`CUE_WIRE_STEP_MAX_EVENTS`)
    /// and the replay harness caps a sample at the same number
    /// (`REPLAY_MAX_EVENTS_PER_SAMPLE`), so the cap is applied HERE —
    /// upstream of the shadow kernel, the trace recorder, and the Pico
    /// link alike — rather than at any one consumer. Truncating at a
    /// consumer would feed the two kernels different event sets and
    /// manufacture exactly the divergence the shadow exists to catch
    /// (RFC 0006 D3). `CuePicoLinkTests` pins this against
    /// `CuePicoWire.stepMaxEvents` so the two cannot drift apart.
    public static let maxEventsPerStep = 16
    private var matcher: SegmentMatcher
    private var tracker: RouteEventTracker
    private let policy: CuePolicy
    public let recorder: RideTraceRecorder
    /// Shared across rides (RideSessionController owns one instance and
    /// injects it into each ride) — reference type, so reviews/markers
    /// recorded on past rides bias live cueing on this one (RFC 0002).
    private let personalMemoryStore: PersonalMemoryStore
    private var lastTMs: UInt32?
    /// Node-order bearing per segment, built once — the comparand a fix's
    /// course is resolved against to decide which way the rider is
    /// travelling a segment whose memory record is direction-gated (cue#30).
    /// Segments with no bearing (degenerate geometry) are simply absent.
    private let segmentBearingDeg: [UInt32: Double]
    /// Travel direction latched per segment while it is in play (cue#30),
    /// and the candidate accumulating evidence for a segment not yet latched.
    ///
    /// Held rather than recomputed per sample because course jitter near the
    /// 90° gate would otherwise dither the bias and fill the trace's
    /// personal_memory[] with change points describing GPS noise. Mirrors
    /// RouteEventTracker.entryEndpoint, which latches the endpoint a zone was
    /// entered through for the same reason.
    ///
    /// CORROBORATED before it latches, though — `directionLatchSamples`
    /// consecutive samples must agree, the same discipline
    /// SegmentMatcher.hysteresisSamples applies so "a single heading spike
    /// cannot flap the match". Latching on the first fix would let one bad
    /// course decide an entire approach: a transient reading 91° off the
    /// segment latches the wrong way, every correct fix afterwards is
    /// ignored, and a directional zone is gated OUT for the whole approach.
    /// That is a SUPPRESSED cue — strictly worse than the pre-cue#30
    /// behavior of applying the record both ways, and not a direction this
    /// feature may fail in.
    ///
    /// Before it latches, each sample's own resolution is used PROVISIONALLY
    /// rather than withheld — a rider going the wrong way is gated out from
    /// the first sample, as intended, and a spike costs exactly one sample
    /// instead of an approach. Two nil meanings are kept apart here: no
    /// course at all reads nil and applies the record (the gate cannot reject
    /// what it cannot measure), while a measured-but-uncorroborated course
    /// still gates.
    ///
    /// Scope, precisely: this holds the direction for a segment that STAYS in
    /// play. It cannot help when a course transient is large enough to trip
    /// RouteEventTracker's own directed approach gate, because that drops the
    /// route event entirely and there is then no memory to resolve at all —
    /// pre-existing behavior, unchanged by cue#30 and pinned by
    /// PersonalMemoryIntegrationTests.
    private var latchedDirection: [UInt32: TravelDirection] = [:]
    private var directionCandidate: [UInt32: (direction: TravelDirection, count: Int)] = [:]

    /// Consecutive agreeing samples before a segment's direction latches —
    /// mirrors SegmentMatcher.hysteresisSamples, for the same reason.
    static let directionLatchSamples = 2

    /// `config == nil` applies the spec §8 defaults. `startedAt` is the
    /// ride's wall-clock start, ISO 8601 UTC (caller-formatted so exports
    /// are deterministic under test). `debugGPS` opts one ride into GPS
    /// retention for the debug export (NFR-005: off by default, so
    /// coordinates are never even held in memory on the normal path).
    /// `personalMemoryStore` defaults to a fresh empty store (no memory
    /// influence — existing callers/tests are unaffected) when the caller
    /// has no persistent store to inject.
    public init(segments: [RoadSegment], zones: [SqueezeZone],
                personalMemoryStore: PersonalMemoryStore = PersonalMemoryStore(),
                config: CuePolicyConfig? = nil,
                rideID: String, startedAt: String, debugGPS: Bool = false) {
        matcher = SegmentMatcher(segments: segments)
        tracker = RouteEventTracker(segments: segments, zones: zones)
        policy = CuePolicy(config: config)
        segmentBearingDeg = Dictionary(
            segments.compactMap { segment in
                segment.nodeOrderBearingDeg.map { (segment.id, $0) }
            },
            // Ids are unique by construction (SegmentImporter allocates them
            // from (way, split)); keeping the first is a defensive tie-break,
            // not an expected path.
            uniquingKeysWith: { first, _ in first })
        self.personalMemoryStore = personalMemoryStore
        recorder = RideTraceRecorder(rideID: rideID, startedAt: startedAt,
                                     config: config ?? CuePolicy.defaultConfig(),
                                     retainGPS: debugGPS)
    }

    /// Process one fix. Returns the kernel's decision, or nil when the fix
    /// was dropped: non-increasing timestamp (schema contract: strictly
    /// increasing t_ms so each observation and decision maps to exactly
    /// one sample), or a corrupt coordinate — non-finite or outside the
    /// physical lat/lon range (RideFix is public API; either would trap
    /// in integer conversion or the matcher's grid math, and a corrupt
    /// position has no honest sample anyway).
    @discardableResult
    public func process(_ fix: RideFix) -> CueDecision? {
        guard fix.lat.isFinite, fix.lon.isFinite,
              abs(fix.lat) <= 90, abs(fix.lon) <= 180 else { return nil }
        if let lastTMs, fix.tMs <= lastTMs { return nil }
        lastTMs = fix.tMs

        // Non-finite heading/speed degrade to "unknown"/0 rather than
        // dropping the fix — position is still good, and the kernel's
        // speed gate handles a zero speed.
        let fixHeading = fix.headingDeg.flatMap { $0.isFinite ? $0 : nil }
        let speedMps = fix.speedMps.isFinite ? max(0, fix.speedMps) : 0

        let match = matcher.match(GPSFix(lat: fix.lat, lon: fix.lon,
                                         headingDeg: fixHeading))
        let observed = match.map { tracker.observations(for: $0, headingDeg: fixHeading) } ?? []
        // First N in tracker order (RFC 0006 D3). Applied before the
        // kernel step, so the shadow, the exported trace, and the Pico all
        // see the identical set — a step that overflowed the wire cap
        // downstream would otherwise be dropped from the link only, and
        // the two kernels would silently part company from there on.
        let events = observed.count > Self.maxEventsPerStep
            ? Array(observed.prefix(Self.maxEventsPerStep))
            : observed

        var heading = fixHeading ?? 0
        heading = heading.truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        let sample = RideSample(
            t_ms: fix.tMs,
            lat_e7: Int32((fix.lat * 1e7).rounded()),
            lon_e7: Int32((fix.lon * 1e7).rounded()),
            speed_cmps: UInt16(min(65535, (speedMps * 100).rounded())),
            heading_deg_x10: UInt16((heading * 10).rounded()) % 3600,
            segment_id: match?.segmentID ?? 0)

        // NEUTRAL + 0 is byte-for-byte equivalent to memory == NULL (RFC 0002
        // D5), so it is normalized to nil HERE — before the kernel call, the
        // Pico link, and the recorder alike. Passing it to the kernel while
        // the trace omitted it left the live and replay paths handing the
        // kernel different inputs for the same rider state: no divergence
        // today, since the kernel ignores a NEUTRAL record, but exactly the
        // shape NFR-003 exists to prevent the moment it stops ignoring it.
        // A direction-gated segment resolves NEUTRAL on every pass the other
        // way, so this is now the common case rather than a corner.
        let resolvedMemory = resolveMemory(events: events, headingDeg: fixHeading)
            .flatMap { $0.state == .neutral && $0.noticeBonusS == 0 ? nil : $0 }
        // Drop latches for segments that left play, so the next approach
        // resolves its own direction. A segment dropped by the maxEventsPerStep
        // cap re-latches when it next produces an event — the cap is a wire
        // constraint, and re-resolving is the same work the first approach did.
        let inPlay = Set(events.map(\.segment_id))
        latchedDirection = latchedDirection.filter { inPlay.contains($0.key) }
        directionCandidate = directionCandidate.filter { inPlay.contains($0.key) }
        let kernelMemory = resolvedMemory.map {
            PersonalMemory(segment_id: $0.segmentID, state: $0.state.rawValue,
                           notice_bonus_s: $0.noticeBonusS)
        }
        let decision = policy.step(sample, events: events, memory: kernelMemory)
        // headingKnown lets the export write "unknown course" as an ABSENT
        // heading_deg_x10 (the schema marks it optional) instead of a fake
        // north; replay_cli's opt_u16 defaults absent to 0, exactly what
        // the kernel saw live, so NFR-003 holds in both representations.
        // resolvedMemory is passed through so the export can log
        // personal_memory[] carry-forward change points — a live decision
        // memory influenced that the trace couldn't replay would be an
        // NFR-003 violation (kernel/cue_policy.h's own stated invariant).
        recorder.record(sample: sample, events: events, decision: decision,
                        headingKnown: fixHeading != nil, resolvedMemory: resolvedMemory)
        // Fired here, next to the recorder, so the MCU link and the trace
        // are fed from the same step — the two must never diverge, since
        // the trace is what certifies the ride and the link is what the
        // rider actually feels (RFC 0006 D2).
        onStep?(RideStepContext(sample: sample, events: events,
                                memory: kernelMemory, decision: decision))
        // The marker anchor buffer follows the same GPS-retention opt-in
        // as the recorder (NFR-005): without debugGPS, coordinates are
        // zeroed here too and marker records carry none.
        processedSamples.append(ProcessedSample(
            tMs: fix.tMs, segmentID: sample.segment_id,
            latE7: recorder.retainGPS ? sample.lat_e7 : nil,
            lonE7: recorder.retainGPS ? sample.lon_e7 : nil))
        // Amortized trim: one bulk shift per minute instead of an O(n)
        // element shift every sample once the window fills. mark()'s scan
        // bound grows by at most the slack (60 samples).
        if processedSamples.count >= Self.markerAnchorWindow + 60 {
            processedSamples.removeFirst(
                processedSamples.count - Self.markerAnchorWindow)
        }
        return decision
    }

    // MARK: - Markers (D5, FR-006…007)

    private struct ProcessedSample {
        let tMs: UInt32
        let segmentID: UInt32
        /// nil when the ride did not opt into GPS retention — absence,
        /// not a 0,0 sentinel, so future code cannot mistake the Gulf of
        /// Guinea for a position (NFR-005 defense-in-depth).
        let latE7: Int32?
        let lonE7: Int32?
    }

    private var processedSamples: [ProcessedSample] = []

    /// Marker anchor look-back window: 30 min at 1 Hz. Bounds both memory
    /// and the mark() scan; the longest plausible WCSession outage for a
    /// queued watch marker is comfortably inside it, and an older press
    /// anchors to the oldest retained sample (nearest by time).
    static let markerAnchorWindow = 1800

    /// Record one "unsafe here" marker (FR-006). Both inputs — the voice
    /// App Intent and the watch button — land here, producing the
    /// identical record shape (D5). `atTMs` nil marks the most recent
    /// sample; a queued watch marker that arrives late passes its
    /// original instant so the mark lands on the segment the rider was
    /// actually on, not wherever they are at delivery time. Returns false
    /// (no marker) before the first processed sample — there is no
    /// position to anchor to yet.
    @discardableResult
    public func mark(atTMs: UInt32? = nil) -> Bool {
        guard let last = processedSamples.last else { return false }
        let target = atTMs ?? last.tMs
        // Nearest processed sample by time; ties break toward the earlier
        // sample (deterministic, and the rider was there first).
        var nearest = last
        var bestDelta = UInt32.max
        for sample in processedSamples {
            let delta = sample.tMs > target ? sample.tMs - target : target - sample.tMs
            if delta < bestDelta {
                bestDelta = delta
                nearest = sample
            }
        }
        recorder.recordMarker(tMs: nearest.tMs, segmentID: nearest.segmentID,
                              latE7: nearest.latE7 ?? 0, lonE7: nearest.lonE7 ?? 0)
        personalMemoryStore.recordUnsafeMarker(segmentID: nearest.segmentID)
        forwardedMarkerSegments.append(nearest.segmentID)
        return true
    }

    // MARK: - Personal route memory (RFC 0002)

    /// Resolve the single applicable PersonalMemory for this step, or nil
    /// (memory-free — byte-identical to today). Scoped to v1: only segments
    /// that already produce a RouteEvent this step are considered, reusing
    /// the zone's own distance_to_start_m as the RFC 0002 D3 approach-window
    /// distance. A marker/custom-zone-imported segment with NO squeeze zone
    /// at all gets no approach-window treatment yet — a known limitation
    /// flagged in the implementation plan, not solved here; the fully
    /// general version needs on-demand graph-distance queries against
    /// RouteEventTracker's road graph for arbitrary remembered segments.
    private func resolveMemory(events: [RouteEvent], headingDeg: Double?) -> ResolvedPersonalMemory? {
        // Once per DISTINCT segment, not once per event. Two events can name
        // the same segment in one step (overlapping zones), and resolving per
        // event would advance the corroboration counter twice on one fix —
        // latching in a single step and defeating the guard entirely.
        var directions: [UInt32: TravelDirection?] = [:]
        for segmentID in Set(events.map(\.segment_id)) {
            directions[segmentID] = travelDirection(on: segmentID, headingDeg: headingDeg)
        }
        var best: (event: RouteEvent, resolved: ResolvedPersonalMemory)?
        for event in events {
            // flatMap, not `?? nil`: both collapse the double Optional a
            // dictionary lookup of an Optional value produces, but `?? nil`
            // reads like a guard against a missing key and invites someone to
            // "simplify" it into a force-unwrap.
            let direction = directions[event.segment_id].flatMap { $0 }
            guard let resolved = personalMemoryStore.resolved(for: event.segment_id,
                                                              travelling: direction)
            else { continue }
            if let current = best {
                // RFC 0002 D5 "multi-segment resolution": unsafe > suppress
                // > neutral, ties broken by nearest-ahead (smallest
                // distance_to_start_m) — deterministic regardless of the
                // events array's order (NFR-003).
                let better = resolved.state.precedence > current.resolved.state.precedence
                    || (resolved.state.precedence == current.resolved.state.precedence
                        && event.distance_to_start_m < current.event.distance_to_start_m)
                if better { best = (event, resolved) }
            } else {
                best = (event, resolved)
            }
        }
        return best?.resolved
    }

    /// Which way the rider is travelling `segmentID`: this sample's own
    /// resolution until `directionLatchSamples` consecutive samples agree,
    /// the latched one after that. nil — which the store reads as "cannot
    /// reject anything" — only when there is nothing to measure: no course on
    /// the fix, or no bearing for the segment.
    ///
    /// The comparand is the EVENT's segment, not the matched one: memory
    /// applies to a segment plus an approach window ahead of it (RFC 0002
    /// D3), and "forward" is defined by that segment's own node order, so
    /// judging it against the road the rider currently occupies would be
    /// meaningless for anything upcoming. On approach this is a heuristic —
    /// course now versus a segment not yet reached — bounded by the 90° gate,
    /// by corroboration, and by the fact that an unresolved direction applies
    /// the record rather than withholding it.
    private func travelDirection(on segmentID: UInt32,
                                 headingDeg: Double?) -> TravelDirection? {
        if let latched = latchedDirection[segmentID] { return latched }
        guard let headingDeg, let bearing = segmentBearingDeg[segmentID] else { return nil }
        let direction = TravelDirection.resolve(headingDeg: headingDeg, alongBearingDeg: bearing)
        // One lookup, no force-unwrap: the two-subscript form was sound only
        // because the condition and the unwrap sat in one expression.
        let count = directionCandidate[segmentID]
            .map { $0.direction == direction ? $0.count + 1 : 1 } ?? 1
        if count >= Self.directionLatchSamples {
            directionCandidate[segmentID] = nil
            latchedDirection[segmentID] = direction
        } else {
            directionCandidate[segmentID] = (direction, count)
        }
        return direction
    }

    /// The outcome last forwarded to personalMemoryStore per event id — so
    /// re-grading can undo the PRIOR contribution before applying the new
    /// one (see recordReview below).
    private var lastForwardedOutcome: [UInt32: ReviewOutcome] = [:]

    /// Grade one HEAD_UP (RFC 0003 D7, FR-008) and feed the outcome into
    /// personal route memory (RFC 0002 D1) — the segment the event was
    /// observed on this ride joins the review to the store, so a future
    /// ride benefits from it. recorder.addReview REPLACES (one review per
    /// cue — the trace's own contract); the store must mirror that, or
    /// re-grading the SAME cue several times (false_alarm, reconsider,
    /// useful, reconsider, false_alarm again) would inflate false_alarm to
    /// 2 and wrongly cross the D2 suppress threshold on repeated taps of
    /// ONE cue, not independent evidence across cues. Undo the previously-
    /// forwarded outcome first so only the LATEST grade counts.
    public func recordReview(eventID: UInt32, outcome: ReviewOutcome, reviewedAt: String? = nil) {
        recorder.addReview(eventID: eventID, outcome: outcome, reviewedAt: reviewedAt)
        guard let segmentID = recorder.segmentID(forEventID: eventID) else { return }
        if let previous = lastForwardedOutcome[eventID] {
            personalMemoryStore.undoReview(segmentID: segmentID, outcome: previous)
        }
        personalMemoryStore.recordReview(segmentID: segmentID, outcome: outcome)
        lastForwardedOutcome[eventID] = outcome
    }

    // MARK: - Discard (#135)

    /// Segment ids this ride's mark() calls fed into the shared store, in
    /// order — the discard rollback's ledger. Marks are forwarded (and
    /// persisted) the moment they happen so a crash mid-ride loses
    /// nothing; discarding the ride reverses them after the fact instead.
    private var forwardedMarkerSegments: [UInt32] = []

    /// Reverse every personal-memory contribution this ride made (#135):
    /// each mark()-ed segment loses one marker count, and each graded
    /// event loses its LATEST forwarded outcome (re-grades already undid
    /// the earlier ones). A discarded ride contributes nothing — evidence
    /// from PAST rides on the same segments is untouched, because undo
    /// decrements counters rather than deleting history (NFR-005 /
    /// RFC 0002). Idempotent by construction: both ledgers are cleared,
    /// so a second call is a no-op. Event ids iterate sorted for
    /// deterministic store mutation order (NFR-003 discipline).
    public func undoPersonalMemoryContributions() {
        for segmentID in forwardedMarkerSegments {
            personalMemoryStore.undoUnsafeMarker(segmentID: segmentID)
        }
        forwardedMarkerSegments = []
        for eventID in lastForwardedOutcome.keys.sorted() {
            guard let outcome = lastForwardedOutcome[eventID],
                  let segmentID = recorder.segmentID(forEventID: eventID) else { continue }
            personalMemoryStore.undoReview(segmentID: segmentID, outcome: outcome)
        }
        lastForwardedOutcome = [:]
    }
}
