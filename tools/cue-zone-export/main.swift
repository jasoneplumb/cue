// Intent: CLI companion to webmap.dev#227 — turn an Overpass `out geom;`
//         extract into the squeeze-zone overlay GeoJSON, using the SAME
//         importer and scorer the app runs (one source of truth; no
//         re-implementation). Usage:
//           swift run cue-zone-export <overpass.json> [-o out.geojson]
//                                     [--custom-zones <zones.geojson>]
//         --custom-zones snaps a webmap.dev custom-zone export and lets those
//         segments qualify where the region's own tagging cannot (#38), so an
//         operator can see what their drawn zones actually unlock BEFORE
//         riding. Without it, a region that scores nothing is indistinguishable
//         from zones that silently do not work.
// Privacy: input and output both reveal the region (NFR-005) — keep them
//          off git. The default output lands in the INPUT FILE'S
//          directory (a CWD-relative input resolves to the CWD, which may
//          be the repo); the *.geojson gitignore entry is the guard that
//          actually keeps region data out of git either way.
import CueMapImport
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var customZonesPath: String?
if let flagIndex = arguments.firstIndex(of: "--custom-zones") {
    guard flagIndex + 1 < arguments.count else { fail("--custom-zones requires a path") }
    customZonesPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
var outputPath: String?
if let flagIndex = arguments.firstIndex(of: "-o") {
    guard flagIndex + 1 < arguments.count else { fail("-o requires a path") }
    outputPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
guard arguments.count == 1 else {
    fail("usage: cue-zone-export <overpass.json> [-o out.geojson] [--custom-zones <zones.geojson>]")
}
let inputURL = URL(fileURLWithPath: arguments[0])
let outputURL = outputPath.map(URL.init(fileURLWithPath:))
    ?? inputURL.deletingLastPathComponent()
        .appendingPathComponent("squeeze-zones.geojson")

do {
    let extract = try OverpassExtract(data: Data(contentsOf: inputURL))
    let segments = try SegmentImporter.deriveSegments(from: extract)
    // Snapped with the same code the app's "Import custom zones…" runs, so
    // what this prints is what the phone will do (#38).
    var riderAsserted: Set<UInt32> = []
    if let customZonesPath {
        let features = try CustomZoneImport.parseFeatures(
            from: Data(contentsOf: URL(fileURLWithPath: customZonesPath)))
        let match = CustomZoneImport.matchSegments(for: features, segments: segments)
        riderAsserted = Set(match.directionsBySegment.keys)
        print("custom zones: \(features.count) drawn -> \(riderAsserted.count) segment(s) "
            + "asserted, \(match.unmatchedZoneIDs.count) zone(s) matched no segment")
    }
    let zones = SqueezeScorer.scoreZones(from: segments, riderAsserted: riderAsserted)
    let geojson = try ZoneGeoJSON.encode(zones: zones, segments: segments)
    try geojson.write(to: outputURL, options: .atomic)
    let members = zones.reduce(0) { $0 + $1.segmentIDs.count }
    print("""
    \(extract.ways.count) ways -> \(segments.count) segments -> \
    \(zones.count) zones (\(members) member segments)
    wrote \(outputURL.path)
    """)
    if !zones.isEmpty {
        let lengths = zones.map { Int($0.lengthM.rounded()) }.sorted(by: >)
        print("zone lengths (m): \(lengths.prefix(8).map(String.init).joined(separator: ", "))")
    }
} catch {
    fail("error: \(error)")
}
