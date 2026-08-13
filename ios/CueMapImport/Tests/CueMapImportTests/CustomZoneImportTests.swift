// Intent: Tests for parsing webmap.dev's custom-zones GeoJSON export and
//         snapping it to imported segments (synthetic equator geometry,
//         no real location — NFR-005, same convention as SegmentMatcherTests).
import XCTest
@testable import CueMapImport

final class CustomZoneImportTests: XCTestCase {
    private func segment(id: UInt32, from: (lat: Double, lon: Double),
                         to: (lat: Double, lon: Double)) -> RoadSegment {
        RoadSegment(id: id, osmWayID: Int64(id), splitSequence: 0,
                   nodeIDs: [Int64(id) * 10, Int64(id) * 10 + 1],
                   latE7: [Int32((from.lat * 1e7).rounded()), Int32((to.lat * 1e7).rounded())],
                   lonE7: [Int32((from.lon * 1e7).rounded()), Int32((to.lon * 1e7).rounded())],
                   lengthM: 111,
                   attributes: RoadAttributes(tags: ["highway": "secondary"]))
    }

    private func featureCollectionJSON(_ features: [[String: Any]]) -> Data {
        // swiftlint-safe: JSONSerialization round trip needs no NSNull handling here.
        try! JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    private func feature(id: String, coordinates: [[Double]],
                         label: String? = nil, createdAt: String = "2026-07-21T00:00:00.000Z",
                         kind: String = "custom_zone") -> [String: Any] {
        var properties: [String: Any] = ["kind": kind, "id": id, "created_at": createdAt]
        if let label { properties["label"] = label }
        return [
            "type": "Feature",
            "geometry": ["type": "LineString", "coordinates": coordinates],
            "properties": properties,
        ]
    }

    // MARK: - parseFeatures

    func testParsesAValidFeatureCollection() throws {
        let data = featureCollectionJSON([
            feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]], label: "Narrow bridge"),
        ])
        let features = try CustomZoneImport.parseFeatures(from: data)
        XCTAssertEqual(features, [
            CustomZoneFeature(id: "zone-1", createdAt: "2026-07-21T00:00:00.000Z",
                              label: "Narrow bridge", coordinates: [[0, 0], [0.001, 0]]),
        ])
    }

    func testAcceptsAFeatureWithNoLabel() throws {
        let data = featureCollectionJSON([feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]])])
        let features = try CustomZoneImport.parseFeatures(from: data)
        XCTAssertNil(features[0].label)
    }

    func testAcceptsAnEmptyFeatureCollection() throws {
        XCTAssertEqual(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([])), [])
    }

    func testThrowsOnInvalidJSON() {
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: Data("{not json".utf8))) {
            XCTAssertEqual($0 as? CustomZoneImportError, .invalidJSON)
        }
    }

    func testThrowsWhenRootIsNotAFeatureCollection() {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "Feature"])
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: data)) {
            XCTAssertEqual($0 as? CustomZoneImportError, .notAFeatureCollection)
        }
    }

    func testThrowsOnNonLineStringGeometry() {
        var bad = feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]])
        bad["geometry"] = ["type": "Point", "coordinates": [0, 0]]
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([bad]))) {
            guard case .malformedFeature(let index, _) = $0 as? CustomZoneImportError else {
                return XCTFail("expected .malformedFeature")
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testThrowsOnLineStringWithFewerThanTwoPositions() {
        let bad = feature(id: "zone-1", coordinates: [[0, 0]])
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([bad])))
    }

    func testThrowsWhenKindIsNotCustomZone() {
        let bad = feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]], kind: "squeeze_zone")
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([bad])))
    }

    func testThrowsAllOrNothingWhenOnlyALaterFeatureIsMalformed() {
        let good = feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]])
        var bad = feature(id: "zone-2", coordinates: [[0, 0], [0.001, 0]])
        bad["properties"] = ["kind": "custom_zone", "created_at": "2026-07-21T00:00:00.000Z"]  // missing id
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([good, bad]))) {
            guard case .malformedFeature(let index, _) = $0 as? CustomZoneImportError else {
                return XCTFail("expected .malformedFeature")
            }
            XCTAssertEqual(index, 1)
        }
    }

    // MARK: - matchSegments

    func testZoneNearASegmentMatchesIt() {
        let segments = [segment(id: 7, from: (0, 0), to: (0, 0.001))]
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0.0005, 0.00001]])]  // ~1 m off the line
        let result = CustomZoneImport.matchSegments(for: features, segments: segments)
        XCTAssertEqual(result.matches["zone-1"], [7])
        XCTAssertTrue(result.unmatchedZoneIDs.isEmpty)
    }

    func testZoneFarFromEverySegmentIsUnmatched() {
        let segments = [segment(id: 7, from: (0, 0), to: (0, 0.001))]
        // ~0.01° away (~1.1 km at the equator) — far outside matchRadiusM.
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0.0005, 0.01]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: segments)
        XCTAssertNil(result.matches["zone-1"])
        XCTAssertEqual(result.unmatchedZoneIDs, ["zone-1"])
    }

    func testZoneSpanningTwoSegmentsMatchesBoth() {
        let segments = [
            segment(id: 7, from: (0, 0), to: (0, 0.001)),
            segment(id: 8, from: (0, 0.002), to: (0, 0.003)),
        ]
        // One vertex near segment 7, another near segment 8.
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0.0005, 0.00001], [0.0025, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: segments)
        XCTAssertEqual(result.matches["zone-1"], [7, 8])
    }

    func testEmptySegmentsListLeavesEveryZoneUnmatched() {
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0, 0], [0.001, 0]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [])
        XCTAssertEqual(result.unmatchedZoneIDs, ["zone-1"])
    }

    // MARK: - personalMemoryChangePoints

    func testLogsAnActivationAndADeactivation() {
        let points = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: [7],
            sampleTMs: [0, 1000, 2000, 3000],
            observedSegmentIDs: [1000: [7], 2000: [7]])
        XCTAssertEqual(points, [
            .init(tMs: 1000, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 3000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
        ])
    }

    func testNoChangePointsWhenTheMatchedSegmentIsNeverObserved() {
        let points = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: [7],
            sampleTMs: [0, 1000, 2000],
            observedSegmentIDs: [1000: [99]])
        XCTAssertEqual(points, [])
    }

    func testConsecutiveSamplesWithTheSameObservationLogOnlyOneChangePoint() {
        let points = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: [7],
            sampleTMs: [0, 1000, 2000, 3000],
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7], 3000: [7]])
        XCTAssertEqual(points, [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
    }

    func testZoneActiveAtTheLastSampleEmitsNoTerminalClearRecord() {
        // RFC 0002 D6's "clear on ride end" hazard exists for a reason, but
        // this tool deliberately does NOT synthesize a terminal clear
        // record when the matched segment is still active at the trace's
        // own last sample — same reasoning as RideTraceRecorder's live
        // export (see its "Deliberately NOT appending" comment): a
        // synthetic clear stamped after the last sample would make that
        // sample replay under NEUTRAL even though the live ride (or, here,
        // the what-if scenario) was UNSAFE for it. replay_main.c's
        // end-of-trace "carry-forward-active" warning is the deliberate,
        // non-failing signal for this — not a gap to fill.
        let points = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: [7],
            sampleTMs: [0, 1000, 2000],
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7]])
        XCTAssertEqual(points, [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
    }

    func testTiesBetweenMatchedSegmentsBreakOnSmallestID() {
        let points = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: [7, 3],
            sampleTMs: [0],
            observedSegmentIDs: [0: [7, 3]])
        XCTAssertEqual(points, [.init(tMs: 0, segmentID: 3, state: "UNSAFE", noticeBonusS: 0)])
    }
}
