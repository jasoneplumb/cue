// Intent: The GeoJSON export contract (webmap.dev#227) pinned: one
//         LineString per zone member segment, RFC 7946 [lon, lat] order,
//         §7 evidence carried verbatim, stale members skipped, and
//         byte-stable output. Synthetic equator fixture (NFR-005).
import XCTest
@testable import CueMapImport

final class ZoneGeoJSONTests: XCTestCase {
    // Two-way fixture: an arterial that scores (explicit cycleway=no) and
    // a residential that must not.
    private func makeFixture() throws -> ([RoadSegment], [SqueezeZone]) {
        let squeeze = OverpassWay(
            id: 200,
            tags: ["highway": "secondary", "lanes": "2", "maxspeed": "45 mph",
                   "cycleway": "no"],
            nodes: [10, 11, 12, 13, 14, 15, 16, 17],
            // lat deliberately nonzero and distinct from every lon value,
            // so the [lon, lat] order assertion can actually fail if the
            // axes are swapped.
            geometry: (0...7).map { OverpassCoordinate(lat: 0.0005, lon: Double($0) * 0.001) })
        let quiet = OverpassWay(
            id: 100, tags: ["highway": "residential"], nodes: [20, 21],
            geometry: [OverpassCoordinate(lat: 0.001, lon: 0),
                       OverpassCoordinate(lat: 0.001, lon: 0.001)])
        let segments = try SegmentImporter.deriveSegments(
            from: OverpassExtract(ways: [squeeze, quiet]))
        return (segments, SqueezeScorer.scoreZones(from: segments))
    }

    func testOneFeaturePerMemberWithContractProperties() throws {
        let (segments, zones) = try makeFixture()
        XCTAssertEqual(zones.count, 1)
        let data = try ZoneGeoJSON.encode(zones: zones, segments: segments)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(root["type"] as? String, "FeatureCollection")
        let features = root["features"] as! [[String: Any]]
        XCTAssertEqual(features.count, zones[0].segmentIDs.count)

        let first = features[0]
        let geometry = first["geometry"] as! [String: Any]
        XCTAssertEqual(geometry["type"] as? String, "LineString")
        // RFC 7946: [lon, lat]. The fixture's lat (0.0005) is not any
        // node's lon (multiples of 0.001), so a swapped axis order fails.
        let coordinates = geometry["coordinates"] as! [[Double]]
        XCTAssertEqual(coordinates[0][1], 0.0005, accuracy: 1e-9)
        XCTAssertNotEqual(coordinates[0][0], 0.0005, accuracy: 1e-9)

        let properties = first["properties"] as! [String: Any]
        XCTAssertEqual(properties["event_id"] as? Int, Int(zones[0].eventID))
        XCTAssertEqual(properties["severity"] as? Int, Int(zones[0].severity))
        XCTAssertEqual(properties["confidence"] as? Int, Int(zones[0].confidence))
        XCTAssertEqual(properties["reasons_bitmask"] as? Int,
                       Int(zones[0].reasonsBitmask))
        XCTAssertEqual(properties["zone_length_m"] as? Int,
                       Int(zones[0].lengthM.rounded()))
        let memberID = UInt32(properties["segment_id"] as! Int)
        let member = segments.first { $0.id == memberID }!
        XCTAssertEqual(properties["segment_length_m"] as? Int,
                       Int(member.lengthM.rounded()))
        XCTAssertNotNil(properties["segment_id"])
    }

    func testStaleMembersAreSkippedNotFatal() throws {
        let (segments, zones) = try makeFixture()
        // Zone from a cache whose extract has since shrunk: drop one
        // member's segment — the export renders the rest.
        let firstMember = zones[0].segmentIDs[0]
        let pruned = segments.filter { $0.id != firstMember }
        let data = try ZoneGeoJSON.encode(zones: zones, segments: pruned)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((root["features"] as! [Any]).count,
                       zones[0].segmentIDs.count - 1)
    }

    func testExportIsDeterministic() throws {
        // Two INDEPENDENT fixture builds — importer and scorer re-run from
        // raw ways — so this pins end-to-end byte stability, not just the
        // purity of encode() over shared references.
        let (segmentsA, zonesA) = try makeFixture()
        let (segmentsB, zonesB) = try makeFixture()
        XCTAssertEqual(try ZoneGeoJSON.encode(zones: zonesA, segments: segmentsA),
                       try ZoneGeoJSON.encode(zones: zonesB, segments: segmentsB))
    }
}
