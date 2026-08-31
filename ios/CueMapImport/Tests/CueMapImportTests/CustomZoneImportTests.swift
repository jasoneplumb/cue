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

    /// A truncated intermediate position can no longer REACH the direction
    /// logic: all three entry points now stop it (parseFeatures and
    /// init(from:) reject; the memberwise init drops). That is stronger than
    /// the conservative fallback it used to rely on — `localBearingDeg`'s
    /// refusal to reuse the incoming edge is now defense-in-depth for a case
    /// no public caller can construct, not the only thing standing between a
    /// malformed file and a zone firing the wrong way.
    func testATruncatedIntermediatePositionCannotReachTheDirectionLogic() throws {
        let features = [CustomZoneFeature(
            id: "zone-1", createdAt: "x", label: nil,
            coordinates: [[0.0002, 0.00001], [0.0006], [0.0003, 0.00001]],
            directional: true)]
        XCTAssertEqual(features[0].coordinates.count, 2, "the bad position is gone before matching")
        let result = CustomZoneImport.matchSegments(for: features, segments: [eastwardSegment()])
        // `try`, not `try?`: an unmatched zone would make this pass for the
        // wrong reason — nil equals nothing either.
        let directions = try XCTUnwrap(result.matches["zone-1"]?[7])
        // 0.0002 -> 0.0003 is eastward, with the segment's node order: the
        // direction of what the rider actually drew, not of a stale edge.
        XCTAssertEqual(directions, ZoneDirectionMask.forward)
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

    /// The memberwise init is the one entry point that cannot report a
    /// failure, so it drops truncated positions rather than trapping on
    /// caller-supplied geometry. What matters is that no path lets one reach
    /// matchSegments, where it would silently degrade a directional zone.
    func testMemberwiseInitDropsTruncatedPositions() {
        let feature = CustomZoneFeature(id: "zone-1", createdAt: "x", label: nil,
                                        coordinates: [[0, 0], [0.001], [0.002, 0]],
                                        directional: true)
        XCTAssertEqual(feature.coordinates, [[0, 0], [0.002, 0]])
    }

    /// A degenerate node at a junction ties across SEGMENTS, not just within
    /// one, so segment id is the final tiebreak — otherwise the winner would
    /// follow edge order and could differ between runs (NFR-003).
    func testACrossSegmentTieResolvesOnSegmentIDNotEdgeOrder() {
        let higher = segment(id: 9, from: (0, 0.0005), to: (0, 0.0005))  // degenerate
        let lower = segment(id: 4, from: (0, 0.0005), to: (0, 0.0005))   // also degenerate
        let features = [directionalZone(id: "zone-1",
                                        coordinates: [[0.0005, 0], [0.0006, 0]])]
        let forward = CustomZoneImport.matchSegments(for: features, segments: [higher, lower])
        let reversed = CustomZoneImport.matchSegments(for: features, segments: [lower, higher])
        XCTAssertEqual(forward.matches["zone-1"]?.keys.first, 4)
        XCTAssertEqual(forward.matches["zone-1"], reversed.matches["zone-1"],
                       "input order must not decide the match")
    }

    func testDecodingRejectsASingleVertexZoneLikeParseFeaturesDoes() {
        // A one-vertex zone has no edge, so a directional one would reach
        // matchSegments and resolve .both — the silent degradation both
        // entry points exist to prevent.
        let json = Data("""
        {"id":"zone-1","createdAt":"x","coordinates":[[0,0]],"directional":true}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CustomZoneFeature.self, from: json))
    }

    /// A mask carrying only reserved bits is non-empty but contains neither
    /// direction, so it would apply on an unknown course while refusing both
    /// known ones — the gate inverted by a byte nobody wrote on purpose.
    func testDecodingMasksOffReservedBits() throws {
        let decoded = try JSONDecoder().decode(ZoneDirectionMask.self, from: Data("4".utf8))
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertFalse(decoded.applies(to: nil))
        XCTAssertEqual(try JSONDecoder().decode(ZoneDirectionMask.self, from: Data("7".utf8)),
                       .both, "real direction bits survive the mask")
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

    /// These cases are about carry-forward compression, not direction, so
    /// they use bidirectional zones and headingless samples — the shape every
    /// pre-cue#30 trace has.
    private func bidirectionalSamples(_ tMs: [UInt32]) -> [CustomZoneImport.TraceSample] {
        tMs.map { CustomZoneImport.TraceSample(tMs: $0, headingDeg: nil) }
    }

    func testLogsAnActivationAndADeactivation() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both],
            samples: bidirectionalSamples([0, 1000, 2000, 3000]),
            observedSegmentIDs: [1000: [7], 2000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [
            .init(tMs: 1000, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 3000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
        ])
    }

    func testNoChangePointsWhenTheMatchedSegmentIsNeverObserved() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both],
            samples: bidirectionalSamples([0, 1000, 2000]),
            observedSegmentIDs: [1000: [99]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [])
    }

    func testConsecutiveSamplesWithTheSameObservationLogOnlyOneChangePoint() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both],
            samples: bidirectionalSamples([0, 1000, 2000, 3000]),
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7], 3000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
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
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both],
            samples: bidirectionalSamples([0, 1000, 2000]),
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
    }

    func testTiesBetweenMatchedSegmentsBreakOnSmallestID() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both, 3: .both],
            samples: bidirectionalSamples([0]),
            observedSegmentIDs: [0: [7, 3]],
            segmentBearingDeg: [7: 90, 3: 90])
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 3, state: "UNSAFE", noticeBonusS: 0)])
    }

    // MARK: - personalMemoryChangePoints: direction (cue#30)

    /// Segment 7's node order runs east (bearing 90), so a course of 90 is
    /// .forward along it and 270 is .backward.
    private func heading(_ deg: Double, at tMs: [UInt32]) -> [CustomZoneImport.TraceSample] {
        tMs.map { CustomZoneImport.TraceSample(tMs: $0, headingDeg: deg) }
    }

    func testDirectionalZoneAppliesOnlyOnSamplesTravellingItsWay() {
        let withIt = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: heading(90, at: [0, 1000]),
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(withIt.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
        XCTAssertEqual(withIt.ungatedSamples, 0)

        let againstIt = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: heading(270, at: [0, 1000]),
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(againstIt.changePoints, [])
        XCTAssertEqual(againstIt.ungatedSamples, 0)
    }

    /// heading_deg_x10 is optional (NFR-005). A trace without it cannot gate
    /// anything, so a directional zone falls back to the pre-cue#30 answer —
    /// applied both ways — and every affected sample is counted so the caller
    /// can warn or refuse rather than quietly overstate the what-if.
    func testHeadinglessSamplesApplyDirectionalZonesBothWaysAndAreCounted() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: bidirectionalSamples([0, 1000, 2000]),
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [
            .init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 2000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
        ])
        XCTAssertEqual(resolved.ungatedSamples, 2, "only the samples that observed the segment")
    }

    /// A segment with no bearing also yields a nil direction, but it is a
    /// different problem: no re-recording can supply a bearing the geometry
    /// does not have, so telling the operator to re-record would be advice
    /// that cannot work. Counted apart, and never as an ungated sample.
    func testABearinglessSegmentIsReportedApartFromAMissingCourse() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: heading(90, at: [0, 1000]),
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [:])  // degenerate segment — no bearing
        XCTAssertEqual(resolved.ungatedSamples, 0, "the trace's course was fine")
        XCTAssertEqual(resolved.undirectedSegments, 1)
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)],
                       "and the zone still applies rather than being silently dropped")
    }

    /// The offline mirror of #32's per-segment latch fix: a repeated segment
    /// id in one sample's observations must not advance corroboration twice.
    func testARepeatedSegmentInOneSampleDoesNotLatchTwice() {
        let samples = [
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 265),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: 90),
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            observedSegmentIDs: [0: [7, 7], 1000: [7, 7], 2000: [7, 7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 1000, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)],
                       "the spiked first sample gates out; it must not latch backward")
    }

    /// The two causes must be disjoint: a segment that is BOTH bearingless
    /// and on a headingless sample used to land in both counters, so the CLI
    /// printed "re-record with debug-GPS" beside "re-recording cannot change
    /// this" about the same segment.
    func testABearinglessSegmentIsNotAlsoCountedAsAMissingCourse() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: bidirectionalSamples([0, 1000]),  // no heading either
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [:])                    // and no bearing
        XCTAssertEqual(resolved.undirectedSegments, 1)
        XCTAssertEqual(resolved.ungatedSamples, 0,
                       "re-recording cannot help here, so it must not be advised")
    }

    /// A latched segment stays gated when a later sample drops its course,
    /// so those samples are NOT ungated. Counting on the sample's own heading
    /// instead of the resolved direction reported zones the latch had in fact
    /// resolved — a false re-record warning, and a spurious --strict refusal.
    func testALatchedSegmentIsNotCountedAsUngatedWhenCourseDropsOut() {
        let samples = [
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 90),  // latches .forward
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: nil), // course drops
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.ungatedSamples, 0,
                       "the latch resolved the direction — nothing to re-record for")
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
    }

    func testABidirectionalZoneIsNeverCountedAsUngated() {
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .both],
            samples: bidirectionalSamples([0, 1000]),
            observedSegmentIDs: [0: [7], 1000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.ungatedSamples, 0)
    }

    /// The offline twin of RideEngine's latch: once two consecutive samples
    /// agree the direction is held, so a later course spike cannot flip the
    /// zone off and back on.
    func testDirectionIsLatchedOnceCorroborated() {
        let samples = [
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 90),  // latches .forward
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: 265), // absorbed
            CustomZoneImport.TraceSample(tMs: 3000, headingDeg: 90),
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7], 3000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints,
                       [.init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0)])
    }

    /// Before the latch corroborates, each sample gates on its own reading —
    /// so a spike inside that window costs exactly that sample, and never the
    /// approach. Same shape as the live engine's behavior, deliberately.
    func testASpikeBeforeCorroborationCostsOnlyThatSample() {
        let samples = [
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 265),
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 3000, headingDeg: 90),
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            observedSegmentIDs: [0: [7], 1000: [7], 2000: [7], 3000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [
            .init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 1000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
            .init(tMs: 2000, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
        ])
    }

    /// The prune has to clear a FULLY LATCHED segment, not just a candidate
    /// mid-corroboration. Only the candidate case was covered, so a prune
    /// that dropped candidates and kept latches would have passed: the held
    /// direction would then outlive the approach that established it and
    /// decide the next one, whichever way the rider went.
    func testAFullyLatchedSegmentAlsoClearsWhenItLeavesPlay() {
        let samples = [
            // Two agreeing samples latch .forward...
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 90),
            // ...the segment leaves play here...
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: 90),
            // ...and returns with the rider going the other way.
            CustomZoneImport.TraceSample(tMs: 3000, headingDeg: 270),
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            observedSegmentIDs: [0: [7], 1000: [7], 3000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [
            .init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 2000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
        ], "a stale .forward latch would have kept the zone applied at t=3000")
    }

    func testASegmentLeavingPlayRelatchesOnItsNextApproach() {
        let samples = [
            CustomZoneImport.TraceSample(tMs: 0, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 1000, headingDeg: 90),
            CustomZoneImport.TraceSample(tMs: 2000, headingDeg: 270),
        ]
        let resolved = CustomZoneImport.personalMemoryChangePoints(
            directionsBySegment: [7: .forward],
            samples: samples,
            // Segment 7 leaves play at t=1000, so t=2000 is a fresh approach
            // and resolves its own (opposite) direction rather than the held one.
            observedSegmentIDs: [0: [7], 2000: [7]],
            segmentBearingDeg: [7: 90])
        XCTAssertEqual(resolved.changePoints, [
            .init(tMs: 0, segmentID: 7, state: "UNSAFE", noticeBonusS: 0),
            .init(tMs: 1000, segmentID: 7, state: "NEUTRAL", noticeBonusS: 0),
        ])
    }
}
