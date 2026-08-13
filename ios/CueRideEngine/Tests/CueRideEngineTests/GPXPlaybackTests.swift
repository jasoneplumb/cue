// Intent: D6 E2E gate on SYNTHETIC geometry (fake ids, equator coordinates
//         — NFR-005): a generated GPX ride drives GPX parse → fixes →
//         matcher → events → kernel → trace, asserting the two D6
//         properties — exactly one HEAD_UP inside the notice window
//         (FR-004), and an exported trace that replays divergence-free
//         (NFR-003). The opt-in tail runs the same loop over a real OSM
//         extract and the real replay_cli binary.
// Layout: way 100 "approach" (residential, lon -0.004→0) shares node 10
//         with way 200 "squeeze" (secondary, lanes=2, 45 mph, cycleway=no,
//         lon 0→0.007) — the RideEngineTests fixture minus the exit way;
//         SqueezeScorer must yield exactly one zone.
import CCuePolicy
import CueKernel
import XCTest
@testable import CueMapImport
@testable import CueRideEngine

final class GPXPlaybackTests: XCTestCase {
    private static let approachWay = OverpassWay(
        id: 100, tags: ["highway": "residential"],
        nodes: [20, 21, 22, 23, 10],
        geometry: (0...4).map { OverpassCoordinate(lat: 0, lon: -0.004 + Double($0) * 0.001) })

    private static let squeezeWay = OverpassWay(
        id: 200,
        tags: ["highway": "secondary", "lanes": "2", "maxspeed": "45 mph",
               "cycleway": "no"],
        nodes: [10, 11, 12, 13, 14, 15, 16, 17],
        geometry: (0...7).map { OverpassCoordinate(lat: 0, lon: Double($0) * 0.001) })

    private func makeRegion() throws -> (segments: [RoadSegment], zone: SqueezeZone) {
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [Self.approachWay, Self.squeezeWay]))
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 1, "fixture must score exactly one zone")
        return (segments, zones[0])
    }

    /// Eastbound points at 6 m/s, 1 s apart, ~2.2 m north of the
    /// centerline — the same geometry as RideEngineTests.eastboundFix, as
    /// a GPX document. `withTimes` toggles between `time`-derived and
    /// synthetic 1000 ms timestamps (both must produce the same ride).
    private func eastboundGPX(seconds: Int, startLon: Double = -0.004,
                              withTimes: Bool = true) -> Data {
        var body = ""
        for second in 0..<seconds {
            let lon = startLon + 6.0 * Double(second) / 111_320.0
            let time = withTimes
                ? "<time>2026-07-11T00:\(String(format: "%02d:%02d", second / 60, second % 60))Z</time>"
                : ""
            body += "<trkpt lat=\"0.00002\" lon=\"\(lon)\">\(time)</trkpt>\n"
        }
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="cue-tests" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>synthetic eastbound</name><trkseg>
        \(body)  </trkseg></trk>
        </gpx>
        """.utf8)
    }

    // MARK: - Parser round-trip

    func testParserExtractsOrderedPointsAndTimes() throws {
        let points = try GPXPlayback.trackPoints(from: eastboundGPX(seconds: 5))
        XCTAssertEqual(points.count, 5)
        for (index, point) in points.enumerated() {
            XCTAssertEqual(point.lat, 0.00002)
            XCTAssertEqual(point.lon, -0.004 + 6.0 * Double(index) / 111_320.0,
                           accuracy: 1e-12)
            XCTAssertNotNil(point.time)
        }
        // 1 s spacing survives the ISO 8601 round trip.
        let start = try XCTUnwrap(points[0].time)
        for (index, point) in points.enumerated() {
            XCTAssertEqual(try XCTUnwrap(point.time).timeIntervalSince(start),
                           Double(index), accuracy: 1e-9)
        }

        let fixes = try GPXPlayback.rideFixes(from: points)
        XCTAssertEqual(fixes.map(\.tMs), [0, 1000, 2000, 3000, 4000])
        for fix in fixes {
            XCTAssertEqual(fix.speedMps, 6.0, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(fix.headingDeg), 90.0, accuracy: 0.01)
        }
        // First fix borrows the second's leg — same values, by contract.
        XCTAssertEqual(fixes[0].speedMps, fixes[1].speedMps)
        XCTAssertEqual(fixes[0].headingDeg, fixes[1].headingDeg)
    }

    func testTimelessTrackGetsSyntheticOneHertzTimestamps() throws {
        let fixes = try GPXPlayback.rideFixes(
            from: eastboundGPX(seconds: 3, withTimes: false))
        XCTAssertEqual(fixes.map(\.tMs), [0, 1000, 2000])
        XCTAssertEqual(fixes[1].speedMps, 6.0, accuracy: 0.01)
    }

    // MARK: - Malformed input is a typed failure, never an empty ride

    func testMalformedInputsRejectedWithTypedErrors() {
        func gpxError(_ document: String) -> GPXPlaybackError? {
            do {
                _ = try GPXPlayback.rideFixes(from: Data(document.utf8))
                return nil
            } catch { return error as? GPXPlaybackError }
        }
        // Not XML at all.
        if case .malformedXML = gpxError("this is not xml") {} else {
            XCTFail("expected malformedXML")
        }
        // Truncated document.
        if case .malformedXML = gpxError("<gpx><trk><trkseg><trkpt lat=\"0\"") {} else {
            XCTFail("expected malformedXML for truncated document")
        }
        // trkpt without coordinates.
        XCTAssertEqual(
            gpxError("<gpx><trk><trkseg><trkpt lon=\"0\"/></trkseg></trk></gpx>"),
            .invalidTrackPoint(line: 1))
        // Unparseable time.
        XCTAssertEqual(
            gpxError("""
            <gpx><trk><trkseg><trkpt lat="0" lon="0"><time>yesterday-ish</time>\
            </trkpt></trkseg></trk></gpx>
            """),
            .invalidTime(value: "yesterday-ish"))
        // Well-formed but trackless.
        XCTAssertEqual(gpxError("<gpx><wpt lat=\"0\" lon=\"0\"/></gpx>"),
                       .noTrackPoints)
        // Reordered timestamps: the engine requires strictly increasing
        // t_ms, so the harness refuses instead of silently dropping fixes.
        XCTAssertEqual(
            gpxError("""
            <gpx><trk><trkseg>\
            <trkpt lat="0" lon="0"><time>2026-07-11T00:00:05Z</time></trkpt>\
            <trkpt lat="0" lon="0.0001"><time>2026-07-11T00:00:04Z</time></trkpt>\
            </trkseg></trk></gpx>
            """),
            .nonChronologicalTime(pointIndex: 1))
    }

    // MARK: - The D6 gate: one cue, in window, divergence-free replay

    func testScenarioEmitsExactlyOneHeadUpInsideNoticeWindow() throws {
        let (segments, zone) = try makeRegion()
        let result = try GPXScenarioRunner.run(
            gpx: eastboundGPX(seconds: 120), segments: segments, zones: [zone])
        XCTAssertEqual(result.headUps.count, 1, "one HEAD_UP per event (FR-004)")
        let cue = try XCTUnwrap(result.headUps.first)
        XCTAssertEqual(cue.eventID, zone.eventID)
        // The runner was given no config, so it runs the shipped defaults —
        // read the window off those rather than restating it, or a §13
        // retune of min/max_notice_s silently falsifies this test.
        let defaults = CuePolicy.defaultConfig()
        let window = Int(defaults.min_notice_s)...Int(defaults.max_notice_s)
        XCTAssertTrue(window.contains(Int(cue.leadTimeS)),
                      "lead time \(cue.leadTimeS)s outside notice window \(window)")
        XCTAssertTrue(result.leadTimesInWindow)
    }

    func testScenarioTraceReplaysDivergenceFree() throws {
        let (segments, zone) = try makeRegion()
        let result = try GPXScenarioRunner.run(
            gpx: eastboundGPX(seconds: 120), segments: segments, zones: [zone])
        let trace = try JSONSerialization.jsonObject(with: result.trace) as! [String: Any]
        let samples = trace["samples"] as! [[String: Any]]
        let observations = trace["route_events"] as! [[String: Any]]
        // Guard against a vacuous pass: with no observations the kernel
        // never gates anything and "divergence-free" proves nothing.
        XCTAssertFalse(observations.isEmpty,
                       "fixture must generate route events for the replay check")
        let recorded = trace["cue_decisions"] as! [[String: Any]]
        XCTAssertEqual(samples.count, 120, "no fix may be dropped")
        XCTAssertEqual(samples.count, recorded.count,
                       "every sample logs its decision")

        // Replay the trace exactly as replay_cli does: per sample, feed the
        // observations stamped with its t_ms, in array order, to a FRESH
        // kernel with the trace's config. Live and replay must agree on
        // every decision — divergence is the bug class this repo names.
        let replay = CuePolicy(config: result.config)  // the resolved config, never assumed
        let observationsByTMs = Dictionary(grouping: observations) {
            UInt32($0["t_ms"] as! Int)
        }
        for (index, sample) in samples.enumerated() {
            let tMs = UInt32(sample["t_ms"] as! Int)
            let events = (observationsByTMs[tMs] ?? [])
                .map { observation in
                    RouteEvent(
                        event_id: UInt32(observation["event_id"] as! Int),
                        family: UInt8(CUE_EVENT_FAMILY_COMPOSITE_SQUEEZE_ZONE),
                        segment_id: UInt32(observation["segment_id"] as! Int),
                        severity: UInt8(observation["severity"] as! Int),
                        confidence: UInt8(observation["confidence"] as! Int),
                        reasons_bitmask: UInt16(observation["reasons_bitmask"] as! Int),
                        distance_to_start_m: Int16(observation["distance_to_start_m"] as! Int),
                        distance_to_end_m: Int16(observation["distance_to_end_m"] as! Int))
                }
            let decision = replay.step(
                RideSample(t_ms: tMs, lat_e7: 0, lon_e7: 0,
                           speed_cmps: UInt16(sample["speed_cmps"] as! Int),
                           // From the trace, exactly as replay_cli reads it
                           // (opt_u16 defaults an absent key to 0).
                           heading_deg_x10: UInt16(sample["heading_deg_x10"] as? Int ?? 0),
                           segment_id: UInt32(sample["segment_id"] as! Int)),
                events: events)
            let expected = recorded[index]
            XCTAssertEqual(decision.isHeadUp ? "HEAD_UP" : "NONE",
                           expected["type"] as? String, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.event_id), expected["event_id"] as? Int, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.reason_code), expected["reason_code"] as? Int, "t_ms \(tMs)")
            XCTAssertEqual(Int(decision.lead_time_s), expected["lead_time_s"] as? Int, "t_ms \(tMs)")
        }
    }

    func testIdenticalScenariosProduceIdenticalTraceBytes() throws {
        let (segments, zone) = try makeRegion()
        let first = try GPXScenarioRunner.run(
            gpx: eastboundGPX(seconds: 90), segments: segments, zones: [zone])
        let second = try GPXScenarioRunner.run(
            gpx: eastboundGPX(seconds: 90), segments: segments, zones: [zone])
        XCTAssertEqual(first.trace, second.trace,
                       "same inputs must yield byte-identical traces (NFR-003)")
        XCTAssertEqual(first.headUps, second.headUps)
    }

    // MARK: - Opt-in: real region, real GPX, real replay_cli binary

    #if os(macOS)
    /// The full D6 round trip with nothing simulated away: a real Overpass
    /// extract, a real ride's GPX, and the actual replay_cli binary. Kept
    /// out of the repo (NFR-005 — real coordinates) and env-gated like
    /// SegmentImporterTests.testRealExtractSmokeOptIn. `--print` re-runs
    /// the kernel over the trace and emits one decision per sample that
    /// carries observations; each must match the trace's recorded decision.
    func testRealDataReplayCLIRoundTripOptIn() throws {
        let env = ProcessInfo.processInfo.environment
        guard let osmPath = env["CUE_OSM_SMOKE"],
              let gpxPath = env["CUE_GPX"],
              let cliPath = env["CUE_REPLAY_CLI"] else {
            throw XCTSkip("""
            set CUE_OSM_SMOKE=/path/to/overpass.json, CUE_GPX=/path/to/ride.gpx, \
            and CUE_REPLAY_CLI=/path/to/replay/build/replay_cli to run
            """)
        }
        let extract = try OverpassExtract(
            data: Data(contentsOf: URL(fileURLWithPath: osmPath)))
        let segments = try SegmentImporter.deriveSegments(from: extract)
        let zones = SqueezeScorer.scoreZones(from: segments)
        let result = try GPXScenarioRunner.run(
            gpx: try Data(contentsOf: URL(fileURLWithPath: gpxPath)),
            segments: segments, zones: zones)
        print("smoke: \(result.headUps.count) HEAD_UP cue(s), "
              + "lead times \(result.headUps.map { Int($0.leadTimeS) }) s, "
              + "in window: \(result.leadTimesInWindow)")

        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-gpx-roundtrip-\(UUID().uuidString).json")
        try result.trace.write(to: traceURL)
        defer { try? FileManager.default.removeItem(at: traceURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--print", traceURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        // Drain before waiting: a big ride can fill the pipe buffer.
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
                       "replay_cli --print must accept the exported trace")
        let printed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: output) as? [[String: Any]])

        // --print emits decisions only for samples carrying observations;
        // the recorded cue_decisions at exactly those samples must match.
        let trace = try JSONSerialization.jsonObject(with: result.trace) as! [String: Any]
        let observedTMs = Set((trace["route_events"] as! [[String: Any]])
            .map { $0["t_ms"] as! Int })
        let expected = (trace["cue_decisions"] as! [[String: Any]])
            .filter { observedTMs.contains($0["t_ms"] as! Int) }
        XCTAssertEqual(printed.count, expected.count,
                       "replay_cli decision count diverges from the trace")
        for (cli, recorded) in zip(printed, expected) {
            let tMs = recorded["t_ms"] as! Int
            XCTAssertEqual(cli["t_ms"] as? Int, tMs)
            XCTAssertEqual(cli["type"] as? String, recorded["type"] as? String,
                           "t_ms \(tMs)")
            XCTAssertEqual(cli["event_id"] as? Int, recorded["event_id"] as? Int,
                           "t_ms \(tMs)")
            XCTAssertEqual(cli["reason_code"] as? Int, recorded["reason_code"] as? Int,
                           "t_ms \(tMs)")
            XCTAssertEqual(cli["lead_time_s"] as? Int, recorded["lead_time_s"] as? Int,
                           "t_ms \(tMs)")
        }
    }
    #endif
}
