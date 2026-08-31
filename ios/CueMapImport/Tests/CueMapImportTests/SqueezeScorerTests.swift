// Intent: Independent fixture tests for the D1b scorer with HAND-COMPUTED
//         expected zones. RFC 0003 D6 records why these must exist: replay
//         never re-scores, so the GPX round-trip is blind to scorer bugs —
//         this suite is the independent leg.
import XCTest
import CCuePolicy
@testable import CueMapImport

final class SqueezeScorerTests: XCTestCase {
    /// Synthetic segment: ids and node ids are hand-assigned; contiguity
    /// is expressed through shared boundary node ids.
    private func segment(id: UInt32, nodes: [Int64],
                         highway: String = "secondary",
                         lanes: Int? = 2, mph: Int? = 45,
                         ridingSpace tags: [String: String] = [:],
                         lengthM: Double = 100) -> RoadSegment {
        var allTags = tags
        allTags["highway"] = highway
        if let lanes { allTags["lanes"] = String(lanes) }
        if let mph { allTags["maxspeed"] = "\(mph) mph" }
        return RoadSegment(id: id, osmWayID: Int64(id), splitSequence: 0,
                           nodeIDs: nodes,
                           latE7: nodes.map { _ in 0 }, lonE7: nodes.map { _ in 0 },
                           lengthM: lengthM,
                           attributes: RoadAttributes(tags: allTags))
    }

    // MARK: - Qualification (the §7 conjunction)

    func testConjunctionRequiresEveryProxy() {
        // Fully qualified baseline: explicit cycleway=no on an arterial.
        let qualified = [segment(id: 5, nodes: [1, 2],
                                 ridingSpace: ["cycleway": "no"])]
        XCTAssertEqual(SqueezeScorer.scoreZones(from: qualified).count, 1)

        // Knock out one proxy at a time — each alone must kill the event.
        for spoiler in [
            segment(id: 5, nodes: [1, 2], highway: "tertiary",
                    ridingSpace: ["cycleway": "no"]),           // not arterial
            segment(id: 5, nodes: [1, 2], lanes: 3,
                    ridingSpace: ["cycleway": "no"]),           // wide
            segment(id: 5, nodes: [1, 2], lanes: nil,
                    ridingSpace: ["cycleway": "no"]),           // lanes unknown
            segment(id: 5, nodes: [1, 2], mph: 35,
                    ridingSpace: ["cycleway": "no"]),           // slow
            segment(id: 5, nodes: [1, 2], mph: nil,
                    ridingSpace: ["cycleway": "no"]),           // speed unknown
            segment(id: 5, nodes: [1, 2],
                    ridingSpace: ["cycleway": "lane"]),         // space exists
        ] {
            XCTAssertTrue(SqueezeScorer.scoreZones(from: [spoiler]).isEmpty,
                          "should not score: \(spoiler.attributes)")
        }
    }

    func testUntaggedAbsenceNeedsSystematicClassTagging() {
        // Ten secondary segments, none tagged for riding space: coverage
        // 0/10 -> silence means nothing -> zero zones (NFR-001).
        var sparse: [RoadSegment] = []
        for i in 1...10 {
            sparse.append(segment(id: UInt32(i),
                                  nodes: [Int64(i * 10), Int64(i * 10 + 1)]))
        }
        XCTAssertTrue(SqueezeScorer.scoreZones(from: sparse).isEmpty)

        // Same class, but 2 of 8 segments carry a cycleway tag: coverage
        // 0.25 meets the threshold, so the 6 untagged ones now score
        // (the 2 tagged ones have dedicated space and do not).
        var covered: [RoadSegment] = []
        for i in 1...6 {
            covered.append(segment(id: UInt32(i),
                                   nodes: [Int64(i * 10), Int64(i * 10 + 1)]))
        }
        for i in 7...8 {
            covered.append(segment(id: UInt32(i),
                                   nodes: [Int64(i * 10), Int64(i * 10 + 1)],
                                   ridingSpace: ["cycleway": "lane"]))
        }
        let zones = SqueezeScorer.scoreZones(from: covered)
        XCTAssertEqual(zones.flatMap { $0.segmentIDs }.sorted(), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(zones.allSatisfy {
            $0.confidence == SqueezeScorer.confidenceMeaningfulAbsence
        })
    }

    // MARK: - Zone merging + hand-computed aggregation

    func testContiguousSegmentsMergeAcrossGaps() {
        // Chain A: 10-11-12 (ids 5,6 share node 11). Chain B: 20-21
        // (id 9). The dedicated-space segment 7 sits between them at
        // nodes 12-20 — it both fails to score AND breaks contiguity.
        let segments = [
            segment(id: 5, nodes: [10, 11], mph: 40,
                    ridingSpace: ["cycleway": "no"], lengthM: 120),
            segment(id: 6, nodes: [11, 12], mph: 45, lengthM: 80),
            segment(id: 7, nodes: [12, 20], ridingSpace: ["cycleway": "track"]),
            segment(id: 9, nodes: [20, 21], mph: 45,
                    ridingSpace: ["shoulder": "no"]),
        ]
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 2)

        // Zone A, hand-computed: eventID = min(5,6) = 5; severity =
        // max(180 @40mph, 200 @45mph) = 200; confidence = min(explicit
        // 190, meaningful-absence 165) = 165 (weakest evidence wins);
        // length 120+80.
        XCTAssertEqual(zones[0].eventID, 5)
        XCTAssertEqual(zones[0].segmentIDs, [5, 6])
        XCTAssertEqual(zones[0].severity, 200)
        XCTAssertEqual(zones[0].confidence, 165)
        XCTAssertEqual(zones[0].lengthM, 200)

        // Zone B: single explicit-no segment at 45 mph.
        XCTAssertEqual(zones[1].eventID, 9)
        XCTAssertEqual(zones[1].segmentIDs, [9])
        XCTAssertEqual(zones[1].severity, 200)
        XCTAssertEqual(zones[1].confidence, 190)
    }

    // MARK: - Kernel contract

    func testReasonsBitmaskComesFromKernelHeader() {
        let zones = SqueezeScorer.scoreZones(
            from: [segment(id: 5, nodes: [1, 2], ridingSpace: ["cycleway": "no"])])
        // The conjunction rule means every zone carries all three §7 bits,
        // and the values are the kernel's own constants — no Swift mirror.
        XCTAssertEqual(UInt32(zones[0].reasonsBitmask),
                       CUE_REASON_NARROW_LANE
                       | CUE_REASON_NO_SHOULDER_OR_BIKE_LANE
                       | CUE_REASON_HIGH_SPEED_CONTEXT)
        XCTAssertEqual(zones[0].reasonsBitmask, 0b111)
    }

    func testThresholdsSitAboveSpecPlaceholderGates() {
        // The POLICY decides, not the scorer: every emitted value must
        // clear the spec §8 placeholder thresholds (128).
        XCTAssertGreaterThan(SqueezeScorer.severityAtFloor, 128)
        XCTAssertGreaterThan(SqueezeScorer.confidenceMeaningfulAbsence, 128)
    }

    func testDeterminism() {
        let segments = [
            segment(id: 5, nodes: [10, 11], ridingSpace: ["cycleway": "no"]),
            segment(id: 6, nodes: [11, 12], ridingSpace: ["cycleway": "no"]),
            segment(id: 9, nodes: [20, 21], ridingSpace: ["shoulder": "no"]),
        ]
        XCTAssertEqual(SqueezeScorer.scoreZones(from: segments),
                       SqueezeScorer.scoreZones(from: segments))
    }

    // MARK: - Rider-asserted scoring (#38)

    /// The reported failure: a whole region where no class clears the
    /// meaningful-absence bar, so nothing scores and a drawn zone has no
    /// event to attach to — inert on exactly the roads the overlay exists
    /// for. One rider-asserted segment is enough to produce a zone.
    func testRiderAssertionQualifiesASegmentASparselyTaggedClassCannot() {
        // Untagged secondary, no riding-space tags anywhere: coverage 0.0.
        let segments = [
            segment(id: 1, nodes: [10, 11]),
            segment(id: 2, nodes: [11, 12]),
        ]
        XCTAssertTrue(SqueezeScorer.scoreZones(from: segments).isEmpty,
                      "baseline: a sparsely tagged class scores nothing")

        let withAssertion = SqueezeScorer.scoreZones(from: segments, riderAsserted: [1])
        XCTAssertEqual(withAssertion.count, 1)
        XCTAssertEqual(withAssertion[0].segmentIDs, [1])
        XCTAssertEqual(withAssertion[0].confidence, SqueezeScorer.confidenceRiderAsserted)
    }

    /// Substitutes for MISSING evidence, never contradicts present evidence:
    /// where OSM says there is riding space, drawing over it changes nothing.
    func testRiderAssertionCannotOverrideTaggedRidingSpace() {
        let withBikeLane = [segment(id: 1, nodes: [10, 11],
                                    ridingSpace: ["cycleway": "lane"])]
        XCTAssertTrue(SqueezeScorer.scoreZones(from: withBikeLane, riderAsserted: [1]).isEmpty)
    }

    /// The class, lane and speed gates are untouched — this is a narrow fix
    /// for the absence gate, not a rider override of the whole conjunction.
    func testRiderAssertionDoesNotBypassTheClassLaneOrSpeedGates() {
        let residential = [segment(id: 1, nodes: [10, 11], highway: "residential")]
        let tooManyLanes = [segment(id: 2, nodes: [10, 11], lanes: 4)]
        let tooSlow = [segment(id: 3, nodes: [10, 11], mph: 25)]
        for (name, segs, id) in [("residential", residential, UInt32(1)),
                                 ("4 lanes", tooManyLanes, UInt32(2)),
                                 ("25 mph", tooSlow, UInt32(3))] {
            XCTAssertTrue(SqueezeScorer.scoreZones(from: segs, riderAsserted: [id]).isEmpty,
                          "\(name) must not score on a rider assertion alone")
        }
    }

    /// An unasserted segment on a well-covered class still scores on the
    /// absence rule, and keeps its own confidence — the new path is additive.
    func testAWellCoveredClassStillScoresWithoutAnyAssertion() {
        let segments = [
            segment(id: 1, nodes: [10, 11]),
            segment(id: 2, nodes: [11, 12], ridingSpace: ["cycleway": "no"]),
            segment(id: 3, nodes: [12, 13], ridingSpace: ["cycleway": "no"]),
            segment(id: 4, nodes: [13, 14], ridingSpace: ["cycleway": "no"]),
        ]
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(zones.count, 1, "coverage is 0.75 — the absence rule applies")
        XCTAssertEqual(zones[0].segmentIDs, [1, 2, 3, 4])
    }

    func testScoringIsUnchangedWhenNothingIsAsserted() {
        let segments = [
            segment(id: 1, nodes: [10, 11], ridingSpace: ["cycleway": "no"]),
            segment(id: 2, nodes: [11, 12], ridingSpace: ["cycleway": "no"]),
        ]
        XCTAssertEqual(SqueezeScorer.scoreZones(from: segments),
                       SqueezeScorer.scoreZones(from: segments, riderAsserted: []))
    }

    // MARK: - rejectionReason diagnostics (#38)

    func testRejectionReasonNamesEachGateItFailed() {
        let coverage = ["secondary": 0.0]
        func why(_ seg: RoadSegment, asserted: Bool = true) -> String {
            SqueezeScorer.rejectionReason(seg, coverage: coverage, riderAsserted: asserted) ?? ""
        }
        XCTAssertTrue(why(segment(id: 1, nodes: [1, 2], highway: "residential"))
            .contains("not an arterial"))
        XCTAssertTrue(why(segment(id: 2, nodes: [1, 2], lanes: 3)).contains("lanes=3"))
        XCTAssertTrue(why(segment(id: 3, nodes: [1, 2], lanes: nil)).contains("no lanes tag"))
        XCTAssertTrue(why(segment(id: 4, nodes: [1, 2], mph: 25)).contains("below the 40 mph"))
        XCTAssertTrue(why(segment(id: 5, nodes: [1, 2], mph: nil)).contains("no maxspeed"))
        XCTAssertTrue(why(segment(id: 6, nodes: [1, 2],
                                  ridingSpace: ["cycleway": "lane"])).contains("dedicated"))
    }

    /// The reported case: a zone drawn where a 2-lane and a 3-lane stretch
    /// meet snaps to both. The 3-lane one is correctly inert, and saying so
    /// is the difference between "my zone is broken" and "that half of it is
    /// a road the scorer deliberately excludes".
    func testAQualifyingSegmentHasNoRejectionReason() {
        let coverage = ["secondary": 0.0]
        XCTAssertNil(SqueezeScorer.rejectionReason(segment(id: 1, nodes: [1, 2]),
                                                   coverage: coverage, riderAsserted: true))
        XCTAssertNotNil(SqueezeScorer.rejectionReason(segment(id: 1, nodes: [1, 2]),
                                                      coverage: coverage, riderAsserted: false),
                        "without the assertion the absence gate still rejects it")
    }
}
