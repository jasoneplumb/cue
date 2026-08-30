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
                         kind: String = "custom_zone", directional: Any? = nil) -> [String: Any] {
        var properties: [String: Any] = ["kind": kind, "id": id, "created_at": createdAt]
        if let label { properties["label"] = label }
        // Any, not Bool: the malformed cases need to plant a non-boolean here.
        if let directional { properties["directional"] = directional }
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

    func testParsesDirectionalTrue() throws {
        let data = featureCollectionJSON([
            feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]], directional: true),
        ])
        XCTAssertTrue(try CustomZoneImport.parseFeatures(from: data)[0].directional)
    }

    func testAbsentDirectionalIsBidirectional() throws {
        let data = featureCollectionJSON([feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]])])
        XCTAssertFalse(try CustomZoneImport.parseFeatures(from: data)[0].directional)
    }

    func testThrowsWhenDirectionalIsPresentButNotABoolean() {
        let bad = feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]], directional: "yes")
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([bad]))) {
            guard case .malformedFeature(_, let reason) = $0 as? CustomZoneImportError else {
                return XCTFail("expected .malformedFeature")
            }
            XCTAssertTrue(reason.contains("directional"), reason)
        }
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
        XCTAssertEqual(result.matches["zone-1"], [7: .both])
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
        XCTAssertEqual(result.matches["zone-1"], [7: .both, 8: .both])
    }

    func testEmptySegmentsListLeavesEveryZoneUnmatched() {
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0, 0], [0.001, 0]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [])
        XCTAssertEqual(result.unmatchedZoneIDs, ["zone-1"])
    }

    // MARK: - matchSegments: direction (cue#30)

    /// Node order runs east (bearing 90°), so a zone drawn west-to-east runs
    /// WITH it and one drawn east-to-west runs against it. Vertices sit ~1 m
    /// north of the line, well inside the snap radius.
    private func eastwardSegment(id: UInt32 = 7) -> RoadSegment {
        segment(id: id, from: (0, 0), to: (0, 0.001))
    }

    private func directionalZone(id: String, coordinates: [[Double]]) -> CustomZoneFeature {
        CustomZoneFeature(id: id, createdAt: "x", label: nil,
                          coordinates: coordinates, directional: true)
    }

    func testDirectionalZoneRunningWithTheSegmentResolvesForward() {
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0002, 0.00001], [0.0008, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["zone-1"], [7: .forward])
    }

    func testDirectionalZoneRunningAgainstTheSegmentResolvesBackward() {
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0008, 0.00001], [0.0002, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["zone-1"], [7: .backward])
    }

    func testNonDirectionalZoneResolvesBothRegardlessOfHowItWasDrawn() {
        let features = [CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                          coordinates: [[0.0008, 0.00001], [0.0002, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["zone-1"], [7: .both])
    }

    /// A zone that doubles back inside one segment asserts both directions —
    /// the union is what the rider drew, and it is the conservative reading.
    func testDirectionalZoneDoublingBackWithinOneSegmentUnionsToBoth() {
        let features = [directionalZone(
            id: "zone-1",
            coordinates: [[0.0002, 0.00001], [0.0008, 0.00001], [0.0003, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["zone-1"], [7: .both])
    }

    /// Two opposing one-way zones on one road: each keeps its own direction,
    /// and the whole-file view sees the segment flagged both ways.
    func testOpposingZonesKeepSeparateDirectionsAndUnionPerSegment() {
        let features = [
            directionalZone(id: "eastbound", coordinates: [[0.0002, 0.00001], [0.0008, 0.00001]]),
            directionalZone(id: "westbound", coordinates: [[0.0008, 0.00001], [0.0002, 0.00001]]),
        ]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["eastbound"], [7: .forward])
        XCTAssertEqual(result.matches["westbound"], [7: .backward])
        XCTAssertEqual(result.directionsBySegment, [7: .both])
    }

    /// A perpendicular zone still resolves deterministically rather than
    /// dropping the match: exactly at the gate resolves forward (stated
    /// tie-break, NFR-003).
    func testPerpendicularDirectionalZoneResolvesForwardAtTheGate() {
        // Drawn north (bearing 0°) across a segment whose node order runs
        // east (90°) — a 90° disagreement, exactly alignmentGateDeg.
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0005, -0.00001], [0.0005, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["zone-1"], [7: .forward])
    }

    func testDirectionalZoneWithNoUsableLocalBearingFallsBackToBoth() {
        // A lone vertex has no edge, and a doubled vertex's edge is
        // zero-length — neither yields a bearing to judge direction from.
        let lone = directionalZone(id: "lone", coordinates: [[0.0005, 0.00001]])
        let doubled = directionalZone(id: "doubled",
                                      coordinates: [[0.0005, 0.00001], [0.0005, 0.00001]])
        let result = CustomZoneImport.matchSegments(for: [lone, doubled],
                                                    segments: [eastwardSegment()])
        XCTAssertEqual(result.matches["lone"], [7: .both])
        XCTAssertEqual(result.matches["doubled"], [7: .both])
    }

    /// A segment whose two nodes coincide has no direction to judge against —
    /// atan2(0, 0) would report north and silently flip forward/backward. The
    /// zone must still snap to it, just without a direction.
    func testDirectionalZoneOnADegenerateSegmentFallsBackToBoth() {
        let degenerate = segment(id: 7, from: (0, 0.0005), to: (0, 0.0005))
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0005, 0.00001], [0.0006, 0.00001]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [degenerate])
        XCTAssertEqual(result.matches["zone-1"], [7: .both])
    }

    func testThrowsWhenAPositionHasFewerThanTwoElements() {
        let bad = feature(id: "zone-1", coordinates: [[0, 0], [0.001]])
        XCTAssertThrowsError(try CustomZoneImport.parseFeatures(from: featureCollectionJSON([bad]))) {
            guard case .malformedFeature(_, let reason) = $0 as? CustomZoneImportError else {
                return XCTFail("expected .malformedFeature")
            }
            XCTAssertTrue(reason.contains("position 1"), reason)
        }
    }

    /// A duplicate OSM node sits exactly ON its neighbouring edges, so the
    /// zero-length edge ties every one of them on distance. The directed edge
    /// has to win, or a single duplicated node would erase the direction of
    /// the road it sits in the middle of.
    func testADegenerateEdgeDoesNotShadowADirectedOneOnADistanceTie() {
        let withDuplicateNode = RoadSegment(
            id: 7, osmWayID: 7, splitSequence: 0, nodeIDs: [70, 71, 72],
            latE7: [0, 0, 0],
            lonE7: [0, 5000, 5000],  // second and third nodes coincide
            lengthM: 55,
            attributes: RoadAttributes(tags: ["highway": "secondary"]))
        // A vertex right at the duplicated node, drawn eastward.
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0005, 0], [0.0009, 0]])]
        let result = CustomZoneImport.matchSegments(for: features, segments: [withDuplicateNode])
        XCTAssertEqual(result.matches["zone-1"], [7: .forward])
    }

    /// A gap in the middle of a zone must not fall back to the INCOMING edge:
    /// on a zone that reverses right after the gap that bearing is the exact
    /// opposite of what was meant, so the zone would fire the wrong way.
    func testAMissingIntermediateVertexYieldsBothNotTheOppositeDirection() throws {
        let features = [CustomZoneFeature(
            id: "zone-1", createdAt: "x", label: nil,
            // Vertex 1 is unusable; vertex 2 reverses back west.
            coordinates: [[0.0002, 0.00001], [0.0006], [0.0003, 0.00001]],
            directional: true)]
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        // `try`, not `try?`: an unmatched zone would make the assertion below
        // pass for the wrong reason — nil is not .forward either.
        let directions = try XCTUnwrap(result.matches["zone-1"]?[7])
        XCTAssertNotEqual(directions, ZoneDirectionMask.forward,
                          "must never invert a zone's direction from a stale incoming edge")
    }

    // MARK: - Codable contract

    func testDecodingRejectsATruncatedPositionLikeParseFeaturesDoes() {
        // Both entry points enforce this, or the weaker one becomes a way in:
        // matchSegments can only SKIP a truncated position, quietly resolving
        // a directional zone to .both with no diagnostic.
        let json = Data("""
        {"id":"zone-1","createdAt":"x","coordinates":[[0,0],[0.001]],"directional":true}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CustomZoneFeature.self, from: json))
    }

    /// Pins the leniency the parse comment claims: JSONSerialization hands
    /// back an NSNumber for `1`, and `as? Bool` bridges it to true. Not a
    /// contract webmap.dev ever exercises — its own parser rejects a
    /// non-boolean — but the comment should not outlive the behavior.
    func testJSONIntegerOneSatisfiesTheBooleanCheck() throws {
        let data = featureCollectionJSON([
            feature(id: "zone-1", coordinates: [[0, 0], [0.001, 0]], directional: 1),
        ])
        XCTAssertTrue(try CustomZoneImport.parseFeatures(from: data)[0].directional)
    }

    func testZoneDirectionMaskCodesAsABareInteger() throws {
        let encoded = try JSONEncoder().encode(ZoneDirectionMask.backward)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "2")
        XCTAssertEqual(try JSONDecoder().decode(ZoneDirectionMask.self, from: Data("3".utf8)),
                       .both)
    }


    func testDecodesAValueEncodedBeforeDirectionalExisted() throws {
        let legacy = Data("""
        {"id":"zone-1","createdAt":"x","coordinates":[[0,0],[0.001,0]]}
        """.utf8)
        let feature = try JSONDecoder().decode(CustomZoneFeature.self, from: legacy)
        XCTAssertFalse(feature.directional)
        XCTAssertNil(feature.label)
    }

    func testRoundTripsThroughJSONCoder() throws {
        let feature = CustomZoneFeature(id: "zone-1", createdAt: "x", label: "Narrow",
                                        coordinates: [[0, 0], [0.001, 0]], directional: true)
        let decoded = try JSONDecoder().decode(
            CustomZoneFeature.self, from: JSONEncoder().encode(feature))
        XCTAssertEqual(decoded, feature)
    }

    // MARK: - TravelDirection / ZoneDirectionMask

    func testResolveSplitsOnTheSameSideOfPerpendicular() {
        XCTAssertEqual(TravelDirection.resolve(headingDeg: 90, alongBearingDeg: 90), .forward)
        XCTAssertEqual(TravelDirection.resolve(headingDeg: 179, alongBearingDeg: 90), .forward)
        XCTAssertEqual(TravelDirection.resolve(headingDeg: 181, alongBearingDeg: 90), .backward)
        XCTAssertEqual(TravelDirection.resolve(headingDeg: 270, alongBearingDeg: 90), .backward)
        // Wraps: 10° vs 350° is a 20° disagreement, not 340°.
        XCTAssertEqual(TravelDirection.resolve(headingDeg: 10, alongBearingDeg: 350), .forward)
    }

    func testMaskAppliesOnlyToTheDirectionsItCarries() {
        XCTAssertTrue(ZoneDirectionMask.forward.applies(to: .forward))
        XCTAssertFalse(ZoneDirectionMask.forward.applies(to: .backward))
        XCTAssertTrue(ZoneDirectionMask.both.applies(to: .backward))
    }

    func testUnknownCourseCannotRejectAnything() {
        XCTAssertTrue(ZoneDirectionMask.forward.applies(to: nil))
        XCTAssertTrue(ZoneDirectionMask.both.applies(to: nil))
        XCTAssertFalse(ZoneDirectionMask([]).applies(to: nil))
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
