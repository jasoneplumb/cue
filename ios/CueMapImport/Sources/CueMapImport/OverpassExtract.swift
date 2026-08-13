// Intent: Decode and validate an OSM region extract (RFC 0003 D1a). The
//         import format is an Overpass `out geom;` JSON response — the same
//         shape the desk tools (osm_tag_audit.sh, d6_gpx_sim.py) already
//         consume — fetched once by the operator and loaded as a file.
//         PBF region extracts are future work; the layer boundary (raw OSM
//         in, segments out, all on-device) is what D1 fixes.
// Pattern: Foundation-only Codable. Validation is loud: an Overpass
//          "remark" means truncated data and fails the import — a partial
//          region silently missing ways would degrade squeeze coverage
//          with no visible symptom (NFR-001's bad direction).
import Foundation

/// Highway classes the rider can plausibly be on — mirrors the class regex
/// in tools/osm_tag_audit.sh so desk audits and on-device imports agree.
public let rideableHighwayClasses: Set<String> = [
    "primary", "secondary", "tertiary", "residential", "unclassified",
    "trunk", "primary_link", "secondary_link", "tertiary_link",
    "living_street",
]

/// One OSM way as delivered by Overpass `out geom;`.
public struct OverpassWay: Decodable, Sendable {
    public let id: Int64
    public let tags: [String: String]
    /// Node ids, parallel to `geometry` (required for the D2 matcher graph).
    public let nodes: [Int64]
    public let geometry: [OverpassCoordinate]
}

public struct OverpassCoordinate: Decodable, Sendable {
    public let lat: Double
    public let lon: Double
}

public enum OverpassExtractError: Error, Equatable {
    /// Overpass reports timeouts/overflows as HTTP 200 plus a "remark" —
    /// indistinguishable from a sparse region unless checked (PR #19).
    case partialData(remark: String)
    /// A way without parallel nodes/geometry arrays means the fetch was
    /// not `out geom;` — the import cannot build segments from it.
    case malformedWay(osmWayID: Int64)
    case noRideableWays
}

/// A validated region extract: rideable ways only, every way carrying
/// parallel node-id and coordinate arrays with at least one edge.
public struct OverpassExtract: Sendable {
    public let ways: [OverpassWay]

    /// Test seam: build an extract from already-validated ways.
    init(ways: [OverpassWay]) {
        self.ways = ways
    }

    public init(data: Data) throws {
        struct Raw: Decodable {
            let remark: String?
            let elements: [Element]
        }
        struct Element: Decodable {
            let type: String
            let id: Int64
            let tags: [String: String]?
            let nodes: [Int64]?
            let geometry: [OverpassCoordinate]?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        if let remark = raw.remark {
            throw OverpassExtractError.partialData(remark: remark)
        }
        var ways: [OverpassWay] = []
        for element in raw.elements where element.type == "way" {
            let tags = element.tags ?? [:]
            guard let highway = tags["highway"],
                  rideableHighwayClasses.contains(highway) else { continue }
            guard let nodes = element.nodes, let geometry = element.geometry,
                  nodes.count == geometry.count, nodes.count >= 2 else {
                throw OverpassExtractError.malformedWay(osmWayID: element.id)
            }
            ways.append(OverpassWay(id: element.id, tags: tags,
                                    nodes: nodes, geometry: geometry))
        }
        guard !ways.isEmpty else { throw OverpassExtractError.noRideableWays }
        // Deterministic downstream ordering regardless of server ordering.
        self.ways = ways.sorted { $0.id < $1.id }
    }
}
