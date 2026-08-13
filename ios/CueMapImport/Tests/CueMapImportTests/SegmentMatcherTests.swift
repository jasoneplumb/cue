// Intent: D2 matcher tests on SYNTHETIC geometries (fake way ids, equator
//         coordinates — no real location, NFR-005). The load-bearing
//         properties: nearest-edge matching with free transitions along
//         the held way, the heading gate rejecting perpendicular roads,
//         way-level hysteresis (hold through a one-fix blip, switch after
//         two consecutive challenges, survive GPS dropouts), conservative
//         nil on no candidate, and determinism for a given fix sequence.
// Layout: way 200 "main" runs east along the equator (lat 0, lon 0→0.007,
//         ~111 m edges → 4 segments); way 100 "parallel" mirrors it ~20 m
//         north (lat 0.00018); way 300 "cross" runs north at lon 0.0035.
//         At the equator: 0.001° lon ≈ 111.3 m, 0.00018° lat ≈ 19.9 m.
import XCTest
@testable import CueMapImport

final class SegmentMatcherTests: XCTestCase {
    private let mainWay = OverpassWay(
        id: 200, tags: ["highway": "secondary"],
        nodes: [10, 11, 12, 13, 14, 15, 16, 17],
        geometry: (0...7).map { OverpassCoordinate(lat: 0, lon: Double($0) * 0.001) })

    private let parallelWay = OverpassWay(
        id: 100, tags: ["highway": "residential"],
        nodes: [20, 21, 22, 23, 24, 25, 26, 27],
        geometry: (0...7).map { OverpassCoordinate(lat: 0.00018, lon: Double($0) * 0.001) })

    private let crossWay = OverpassWay(
        id: 300, tags: ["highway": "residential"], nodes: [30, 31],
        geometry: [OverpassCoordinate(lat: -0.001, lon: 0.0035),
                   OverpassCoordinate(lat: 0.001, lon: 0.0035)])

    private func segments(_ ways: [OverpassWay]) throws -> [RoadSegment] {
        try SegmentImporter.deriveSegments(from: OverpassExtract(ways: ways))
    }

    private func segmentID(_ segments: [RoadSegment], way: Int64,
                           split: UInt16) throws -> UInt32 {
        try XCTUnwrap(segments.first {
            $0.osmWayID == way && $0.splitSequence == split
        }).id
    }

    // MARK: - Nearest-edge matching

    func testMatchesNearestEdgeAndTransitionsFreelyAlongWay() throws {
        let imported = try segments([mainWay])
        var matcher = SegmentMatcher(segments: imported)
        // Ride east ~3.3 m north of the centerline, one fix per segment.
        let matches = [0.0005, 0.0025, 0.0045, 0.0065].map {
            matcher.match(GPSFix(lat: 0.00003, lon: $0, headingDeg: 90))
        }
        let expected = try (0...3).map {
            try segmentID(imported, way: 200, split: UInt16($0))
        }
        // Segment transitions along the held way take effect immediately —
        // hysteresis is way-granular, and these are all way 200.
        XCTAssertEqual(matches.map { $0?.segmentID }, expected)
        for match in matches {
            let match = try XCTUnwrap(match)
            XCTAssertEqual(match.osmWayID, 200)
            XCTAssertEqual(match.distanceM, 3.32, accuracy: 0.5)
            XCTAssertTrue((0.0...1.0).contains(match.edgeT))
        }
    }

    func testBeyondRadiusReturnsNil() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay]))
        // ~88 m north of main — inside the grid neighborhood, outside 50 m.
        XCTAssertNil(matcher.match(GPSFix(lat: 0.0008, lon: 0.001, headingDeg: 90)))
    }

    // MARK: - Heading gate

    func testHeadingGateRejectsPerpendicularRoad() throws {
        let imported = try segments([mainWay, crossWay])
        var matcher = SegmentMatcher(segments: imported)
        // ~5.6 m from the cross road, ~22 m from main — but riding east:
        // the cross road (bearing 0) fails the ±50° gate, main passes.
        let east = matcher.match(GPSFix(lat: 0.0002, lon: 0.00355, headingDeg: 90))
        XCTAssertEqual(try XCTUnwrap(east).osmWayID, 200)
        // Same spot riding north: the gate flips the verdict.
        var northbound = SegmentMatcher(segments: imported)
        let north = northbound.match(GPSFix(lat: 0.0002, lon: 0.00355, headingDeg: 0))
        XCTAssertEqual(try XCTUnwrap(north).osmWayID, 300)
    }

    func testColdStartWithIncompatibleHeadingReturnsNil() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay]))
        // On main but reporting a northbound course: nothing passes the gate.
        XCTAssertNil(matcher.match(GPSFix(lat: 0.00003, lon: 0.002, headingDeg: 0)))
    }

    func testMissingHeadingSkipsGate() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, crossWay]))
        // No course (CoreLocation standstill): nearest road wins ungated.
        let match = matcher.match(GPSFix(lat: 0.0002, lon: 0.00355, headingDeg: nil))
        XCTAssertEqual(try XCTUnwrap(match).osmWayID, 300)
    }

    // MARK: - Hysteresis

    /// Fix ~2 m from main (lat 0.00002) or ~2 m from parallel (lat 0.00016);
    /// either beats the other road by ~15.5 m, well past the 3 m margin.
    private func fix(nearMain: Bool, lon: Double = 0.002) -> GPSFix {
        GPSFix(lat: nearMain ? 0.00002 : 0.00016, lon: lon, headingDeg: 90)
    }

    func testHysteresisHoldsThroughSingleFixBlip() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, parallelWay]))
        let ways = [fix(nearMain: true), fix(nearMain: false),
                    fix(nearMain: true), fix(nearMain: false)]
            .map { matcher.match($0)?.osmWayID }
        // Alternating blips never accumulate two consecutive challenges.
        XCTAssertEqual(ways, [200, 200, 200, 200])
    }

    func testHysteresisSwitchesAfterConsecutiveChallenges() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, parallelWay]))
        let ways = [fix(nearMain: true), fix(nearMain: false), fix(nearMain: false)]
            .map { matcher.match($0)?.osmWayID }
        // Second consecutive challenge flips the hold on that same fix.
        XCTAssertEqual(ways, [200, 200, 100])
    }

    func testDropoutPreservesHeldWay() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, parallelWay]))
        XCTAssertEqual(matcher.match(fix(nearMain: true))?.osmWayID, 200)
        // GPS dropout: no road within radius. Unmatched, but not a reset.
        XCTAssertNil(matcher.match(GPSFix(lat: 0.01, lon: 0.002, headingDeg: 90)))
        // A cold matcher would take parallel here (nearest). The held way
        // survives the dropout, so this is challenge 1 of 2 — still main.
        XCTAssertEqual(matcher.match(fix(nearMain: false))?.osmWayID, 200)
    }

    func testHoldLeavingRadiusReacquiresImmediately() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, crossWay]))
        XCTAssertEqual(matcher.match(
            GPSFix(lat: 0.00003, lon: 0.002, headingDeg: 90))?.osmWayID, 200)
        // Turn north far from main: main is PHYSICALLY out of radius,
        // cross is the only candidate — reacquired without waiting out
        // hysteresis (unlike a heading-gate eviction, tested below).
        let match = matcher.match(GPSFix(lat: 0.0008, lon: 0.00352, headingDeg: 0))
        XCTAssertEqual(try XCTUnwrap(match).osmWayID, 300)
    }

    func testGateEvictionReportsUnmatchedThenSwitches() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, crossWay]))
        // Near the intersection: ~3.3 m from main, ~2.2 m from cross.
        let ways = [90, 0, 0].map {
            matcher.match(GPSFix(lat: 0.00003, lon: 0.00352, headingDeg: Double($0)))
        }.map { $0?.osmWayID }
        // Main is still in radius when the course turns north, so the
        // eviction runs the challenger clock: one unmatched fix (never a
        // single-fix flap), then the switch to cross lands.
        XCTAssertEqual(ways, [200, nil, 300])
    }

    func testGateEvictionBlipRestoresHeldWay() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, crossWay]))
        let ways = [90, 0, 90].map {
            matcher.match(GPSFix(lat: 0.00003, lon: 0.00352, headingDeg: Double($0)))
        }.map { $0?.osmWayID }
        // A one-fix course transient costs one unmatched sample and
        // nothing else — the held way returns as if nothing happened.
        XCTAssertEqual(ways, [200, nil, 200])
    }

    func testMixedChallengeKindsDoNotStackToASwitch() throws {
        var matcher = SegmentMatcher(segments: try segments([mainWay, crossWay]))
        // ~5.5 m from main, ~2.2 m from cross: close enough that cross
        // beats main by more than the 3 m margin once it passes the gate.
        let ways = [90, 45, 0, 0].map {
            matcher.match(GPSFix(lat: 0.00005, lon: 0.00352, headingDeg: Double($0)))
        }.map { $0?.osmWayID }
        // Fix 2 (45°): both roads pass the gate, cross challenges on
        // distance (count 1). Fix 3 (0°): main is gate-evicted — a
        // DIFFERENT evidence kind, so the count restarts rather than
        // riding the distance challenge to an instant switch; the sample
        // reports unmatched. Fix 4 completes the eviction clock.
        XCTAssertEqual(ways, [200, 200, nil, 300])
    }

    func testDegenerateEdgeHasNoPhantomBearing() throws {
        // Consecutive duplicate nodes: the zero-length edge must not
        // enter the index with an atan2(0,0) "north" bearing.
        let degenerate = OverpassWay(
            id: 400, tags: ["highway": "residential"], nodes: [40, 41, 42],
            geometry: [OverpassCoordinate(lat: 0, lon: 0),
                       OverpassCoordinate(lat: 0, lon: 0),
                       OverpassCoordinate(lat: 0, lon: 0.001)])
        let imported = try segments([degenerate])
        // Riding north next to the duplicate point: a phantom north edge
        // would match; the real (eastward) geometry must gate it out.
        var northbound = SegmentMatcher(segments: imported)
        XCTAssertNil(northbound.match(GPSFix(lat: 0.00003, lon: 0, headingDeg: 0)))
        // The way still matches along its real bearing.
        var eastbound = SegmentMatcher(segments: imported)
        XCTAssertEqual(eastbound.match(
            GPSFix(lat: 0.00003, lon: 0.0005, headingDeg: 90))?.osmWayID, 400)
    }

    // MARK: - Determinism

    func testIdenticalFixSequencesProduceIdenticalMatches() throws {
        let imported = try segments([mainWay, parallelWay, crossWay])
        // A sequence that exercises hold, blip, switch, dropout, reacquire.
        let fixes = [
            fix(nearMain: true, lon: 0.0005), fix(nearMain: false, lon: 0.001),
            fix(nearMain: true, lon: 0.0015), fix(nearMain: false, lon: 0.002),
            fix(nearMain: false, lon: 0.0025), fix(nearMain: false, lon: 0.003),
            GPSFix(lat: 0.01, lon: 0.003, headingDeg: 90),
            GPSFix(lat: 0.0002, lon: 0.00355, headingDeg: 0),
            GPSFix(lat: 0.0002, lon: 0.00355, headingDeg: nil),
        ]
        var first = SegmentMatcher(segments: imported)
        var second = SegmentMatcher(segments: imported)
        XCTAssertEqual(fixes.map { first.match($0) }, fixes.map { second.match($0) })
    }
}
