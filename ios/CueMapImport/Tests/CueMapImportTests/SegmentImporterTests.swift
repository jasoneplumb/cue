// Intent: D1a importer tests on SYNTHETIC fixtures (fake way ids, equator
//         coordinates — no real location, NFR-005). The load-bearing
//         properties: loud validation failures, §7 attribute parsing,
//         deterministic node-aligned splitting, stable content-derived
//         ids (golden-pinned — an algorithm change orphans every stored
//         segment_id association), and a trustworthy cache.
import XCTest
@testable import CueMapImport

final class SegmentImporterTests: XCTestCase {
    // Way 200: secondary, ~779 m along the equator (8 nodes, ~111.3 m
    // edges) -> splits at the 250 m cap into 4 segments.
    // Way 100: residential 2-node stub. Footway + node elements: ignored.
    private let fixtureJSON = """
    {"elements": [
      {"type": "node", "id": 1, "lat": 0.0, "lon": 0.0},
      {"type": "way", "id": 300, "tags": {"highway": "footway"},
       "nodes": [1, 2], "geometry": [{"lat": 0.0, "lon": 0.0}, {"lat": 0.0, "lon": 0.001}]},
      {"type": "way", "id": 200,
       "tags": {"highway": "secondary", "name": "Test Arterial", "lanes": "2",
                "maxspeed": "45 mph", "cycleway:right": "lane"},
       "nodes": [10, 11, 12, 13, 14, 15, 16, 17],
       "geometry": [{"lat": 0.0, "lon": 0.000}, {"lat": 0.0, "lon": 0.001},
                    {"lat": 0.0, "lon": 0.002}, {"lat": 0.0, "lon": 0.003},
                    {"lat": 0.0, "lon": 0.004}, {"lat": 0.0, "lon": 0.005},
                    {"lat": 0.0, "lon": 0.006}, {"lat": 0.0, "lon": 0.007}]},
      {"type": "way", "id": 100,
       "tags": {"highway": "residential", "maxspeed": "30"},
       "nodes": [20, 21],
       "geometry": [{"lat": 0.001, "lon": 0.0}, {"lat": 0.001, "lon": 0.001}]}
    ]}
    """

    private func fixtureExtract() throws -> OverpassExtract {
        try OverpassExtract(data: Data(fixtureJSON.utf8))
    }

    // MARK: - Extract validation

    func testDecodeFiltersNonRideableAndSortsByWayID() throws {
        let extract = try fixtureExtract()
        XCTAssertEqual(extract.ways.map(\.id), [100, 200])
    }

    func testRemarkFailsImport() {
        let data = Data(#"{"remark": "runtime error: timeout", "elements": []}"#.utf8)
        XCTAssertThrowsError(try OverpassExtract(data: data)) {
            XCTAssertEqual($0 as? OverpassExtractError,
                           .partialData(remark: "runtime error: timeout"))
        }
    }

    func testWayWithoutGeometryFailsImport() {
        let data = Data("""
        {"elements": [{"type": "way", "id": 42,
                       "tags": {"highway": "residential"}, "nodes": [1, 2]}]}
        """.utf8)
        XCTAssertThrowsError(try OverpassExtract(data: data)) {
            XCTAssertEqual($0 as? OverpassExtractError, .malformedWay(osmWayID: 42))
        }
    }

    func testNoRideableWaysFailsImport() {
        let data = Data(#"{"elements": []}"#.utf8)
        XCTAssertThrowsError(try OverpassExtract(data: data)) {
            XCTAssertEqual($0 as? OverpassExtractError, .noRideableWays)
        }
    }

    // MARK: - §7 attribute parsing

    func testAttributeParsing() throws {
        let segments = try SegmentImporter.deriveSegments(from: fixtureExtract())
        let arterial = try XCTUnwrap(segments.first { $0.osmWayID == 200 })
        XCTAssertEqual(arterial.attributes.lanes, 2)
        XCTAssertEqual(arterial.attributes.maxspeedMph, 45)
        XCTAssertEqual(arterial.attributes.ridingSpace, .dedicatedSpace)  // cycleway:right=lane
        let residential = try XCTUnwrap(segments.first { $0.osmWayID == 100 })
        // Bare "30" is km/h per OSM convention -> 19 mph.
        XCTAssertEqual(residential.attributes.maxspeedMph, 19)
        XCTAssertNil(residential.attributes.lanes)
        XCTAssertEqual(residential.attributes.ridingSpace, .untagged)
    }

    func testRidingSpaceEvidence() {
        func evidence(_ tags: [String: String]) -> RidingSpaceEvidence {
            RoadAttributes(tags: tags).ridingSpace
        }
        // cycleway=no / shoulder=no are explicit ABSENCE, not infrastructure.
        XCTAssertEqual(evidence(["cycleway": "no"]), .explicitNone)
        XCTAssertEqual(evidence(["shoulder": "no"]), .explicitNone)
        XCTAssertEqual(evidence(["cycleway": "lane"]), .dedicatedSpace)
        XCTAssertEqual(evidence(["shoulder": "yes"]), .dedicatedSpace)
        // One real lane beats an explicit-no on the other side.
        XCTAssertEqual(evidence(["cycleway:left": "lane", "cycleway:right": "no"]),
                       .dedicatedSpace)
        // Directional shoulder sub-tags (side in the KEY) count too — a
        // shoulder:right=yes road scoring as a squeeze would be a false
        // positive, the wrong direction for NFR-001.
        XCTAssertEqual(evidence(["shoulder:right": "yes"]), .dedicatedSpace)
        XCTAssertEqual(evidence(["shoulder:both": "no"]), .explicitNone)
        XCTAssertEqual(evidence([:]), .untagged)
    }

    // MARK: - Splitting

    func testLongWaySplitsAtCapWithSharedBoundaryNodes() throws {
        let segments = try SegmentImporter.deriveSegments(from: fixtureExtract())
            .filter { $0.osmWayID == 200 }
        XCTAssertEqual(segments.map(\.splitSequence), [0, 1, 2, 3])
        XCTAssertEqual(segments.map(\.nodeIDs), [
            [10, 11, 12], [12, 13, 14], [14, 15, 16], [16, 17],
        ])
        for segment in segments {
            // Holds because fixture edges are ~111 m. The cap is SOFT in
            // general — see testSingleEdgeExceedingCapIsNotSplit.
            XCTAssertLessThanOrEqual(segment.lengthM,
                                     SegmentImporter.maxSegmentLengthM)
            XCTAssertGreaterThan(segment.lengthM, 0)
        }
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
    }

    func testSingleEdgeExceedingCapIsNotSplit() throws {
        // A two-node way whose sole edge is ~334 m (> cap) must produce
        // exactly one over-cap segment — splits are node-aligned, so the
        // cap is a soft target, never a reason to drop or zero a segment.
        let way = OverpassWay(
            id: 42, tags: ["highway": "residential"], nodes: [0, 1],
            geometry: [OverpassCoordinate(lat: 0, lon: 0),
                       OverpassCoordinate(lat: 0, lon: 0.003)])
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [way]))
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThan(segments[0].lengthM,
                             SegmentImporter.maxSegmentLengthM)
        XCTAssertEqual(segments[0].splitSequence, 0)
    }

    func testTooManySplitsFailsLoudly() {
        // 0.003 degrees of longitude per edge (~334 m) forces one segment
        // per edge; 1025 edges exceeds the 1024-sequence id space.
        let count = 1026
        let way = OverpassWay(
            id: 999,
            tags: ["highway": "residential"],
            nodes: (0..<count).map(Int64.init),
            geometry: (0..<count).map {
                OverpassCoordinate(lat: 0, lon: Double($0) * 0.003)
            })
        XCTAssertThrowsError(
            try SegmentImporter.deriveSegments(from: OverpassExtract(ways: [way]))) {
            XCTAssertEqual($0 as? SegmentImportError, .tooManySplits(osmWayID: 999))
        }
    }

    // MARK: - Stable ids

    func testSegmentIDGoldenValues() {
        // Golden pins: if these change, the derivation algorithm changed
        // and every stored segment_id association silently orphans.
        XCTAssertEqual(SegmentImporter.segmentID(osmWayID: 123_456_789, splitSequence: 0),
                       1_249_501_087)
        XCTAssertEqual(SegmentImporter.segmentID(osmWayID: 123_456_789, splitSequence: 1),
                       2_425_909_226)
        XCTAssertEqual(SegmentImporter.segmentID(osmWayID: 1_498_652_577, splitSequence: 0),
                       3_346_757_778)
    }

    func testSegmentIDNeverZeroOnSweep() {
        for wayID in Int64(1)...2000 {
            for seq in UInt16(0)...3 {
                XCTAssertNotEqual(
                    SegmentImporter.segmentID(osmWayID: wayID, splitSequence: seq), 0)
            }
        }
    }

    func testDerivationIsDeterministic() throws {
        let first = try SegmentImporter.deriveSegments(from: fixtureExtract())
        let second = try SegmentImporter.deriveSegments(from: fixtureExtract())
        XCTAssertEqual(first, second)
    }

    // MARK: - Cache

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-segment-store-\(UUID().uuidString)")
    }

    func testStoreRoundTrip() throws {
        let segments = try SegmentImporter.deriveSegments(from: fixtureExtract())
        let hash = SegmentStore.sha256Hex(of: Data(fixtureJSON.utf8))
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SegmentStore.save(segments, sourceSHA256: hash, to: directory)
        let (manifest, loaded) = try XCTUnwrap(SegmentStore.load(from: directory))
        XCTAssertEqual(manifest.sourceSHA256, hash)
        XCTAssertEqual(manifest.segmentCount, segments.count)
        XCTAssertEqual(loaded, segments)
    }

    func testLoadReturnsNilWithoutCache() throws {
        XCTAssertNil(try SegmentStore.load(from: temporaryDirectory()))
    }

    func testInterruptedRefreshReadsAsNoCache() throws {
        // Simulate a crash inside a cache REFRESH: save() deletes the
        // manifest first, so any interruption before the final manifest
        // write must read as "no usable cache", never as a stale pairing.
        let segments = try SegmentImporter.deriveSegments(from: fixtureExtract())
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SegmentStore.save(segments, sourceSHA256: "old", to: directory)
        // The refresh's first step (manifest delete) ran; then a crash.
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("manifest.json"))
        XCTAssertNil(try SegmentStore.load(from: directory))
    }

    // MARK: - Opt-in real-data smoke test

    /// Runs only when CUE_OSM_SMOKE points at a real Overpass `out geom;`
    /// extract (kept out of the repo — NFR-005). Exercises decode, split,
    /// and the whole-region collision audit on real way-id distributions.
    func testRealExtractSmokeOptIn() throws {
        guard let path = ProcessInfo.processInfo.environment["CUE_OSM_SMOKE"] else {
            throw XCTSkip("set CUE_OSM_SMOKE=/path/to/overpass.json to run")
        }
        let extract = try OverpassExtract(
            data: Data(contentsOf: URL(fileURLWithPath: path)))
        let segments = try SegmentImporter.deriveSegments(from: extract)
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
        XCTAssertFalse(segments.contains { $0.id == 0 })
        let overCap = segments.filter {
            $0.lengthM > SegmentImporter.maxSegmentLengthM
        }
        print("smoke: \(extract.ways.count) ways -> \(segments.count) segments, "
              + "max split seq \(segments.map(\.splitSequence).max() ?? 0), "
              + "\(overCap.count) over-cap single-edge segments "
              + "(max \(Int(overCap.map(\.lengthM).max() ?? 0)) m)")
        let zones = SqueezeScorer.scoreZones(from: segments)
        XCTAssertEqual(SqueezeScorer.scoreZones(from: segments), zones)  // deterministic
        XCTAssertFalse(zones.contains { $0.eventID == 0 })
        print("smoke: \(zones.count) squeeze zones, lengths "
              + "\(zones.map { Int($0.lengthM) }.sorted(by: >).prefix(6)) m, "
              + "severities \(Set(zones.map(\.severity)).sorted()), "
              + "confidences \(Set(zones.map(\.confidence)).sorted())")
    }

    func testUnknownSchemaVersionIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let manifest = #"{"schemaVersion": 99, "sourceSHA256": "x", "segmentCount": 0}"#
        try Data(manifest.utf8).write(
            to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try SegmentStore.load(from: directory)) {
            XCTAssertEqual($0 as? SegmentStoreError, .unknownSchemaVersion(99))
        }
    }
}
