// Intent: GeoJSON export of scored squeeze zones for map-overlay
//         consumption (webmap.dev#227): one LineString feature per zone
//         MEMBER SEGMENT (features sharing an event_id form one logical
//         zone), carrying the §7 evidence verbatim — the overlay decodes
//         reasons_bitmask itself and renders severity/confidence as-is.
// Privacy: the output's geometry IS the imported region (NFR-005): the
//          file is for the operator's own map, never for the repo —
//          *.geojson is gitignored.
// Pattern: Deterministic bytes for identical inputs (sortedKeys; zones
//          by event_id, members in the zone's ascending order), matching
//          the byte-stable convention of the other exporters.
import Foundation

public enum ZoneGeoJSON {
    /// Encode scored zones over their source segments. Members missing
    /// from `segments` are skipped (a zone from a stale cache against a
    /// newer extract) — the overlay renders what can be drawn.
    public static func encode(zones: [SqueezeZone],
                              segments: [RoadSegment]) throws -> Data {
        // uniquingKeysWith: the importer guarantees unique ids, but a
        // public throws API must not trap on caller-supplied duplicates.
        let segmentsByID = Dictionary(segments.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        var features: [Feature] = []
        for zone in zones.sorted(by: { $0.eventID < $1.eventID }) {
            for memberID in zone.segmentIDs {
                guard let segment = segmentsByID[memberID] else { continue }
                features.append(Feature(
                    geometry: Geometry(coordinates: zip(segment.lonE7, segment.latE7)
                        .map { [Double($0.0) / 1e7, Double($0.1) / 1e7] }),
                    properties: Properties(
                        event_id: zone.eventID,
                        segment_id: segment.id,
                        severity: zone.severity,
                        confidence: zone.confidence,
                        reasons_bitmask: zone.reasonsBitmask,
                        zone_length_m: Int(zone.lengthM.rounded()),
                        segment_length_m: Int(segment.lengthM.rounded()))))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FeatureCollection(features: features))
    }

    // GeoJSON RFC 7946 shapes, limited to what the overlay contract needs.
    private struct FeatureCollection: Encodable {
        let type = "FeatureCollection"
        let features: [Feature]
    }

    private struct Feature: Encodable {
        let type = "Feature"
        let geometry: Geometry
        let properties: Properties
    }

    private struct Geometry: Encodable {
        let type = "LineString"
        /// [lon, lat] order per RFC 7946.
        let coordinates: [[Double]]
    }

    private struct Properties: Encodable {
        let event_id: UInt32
        let segment_id: UInt32
        let severity: UInt8
        let confidence: UInt8
        let reasons_bitmask: UInt16
        /// The LOGICAL zone's total length — identical on every member
        /// feature of the same event_id; never sum it across features.
        let zone_length_m: Int
        /// This feature's own polyline length.
        let segment_length_m: Int
    }
}
