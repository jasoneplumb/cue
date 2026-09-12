// Intent: CLI companion to webmap.dev#227 — turn an Overpass `out geom;`
//         extract into the squeeze-zone overlay GeoJSON, using the SAME
//         importer and scorer the app runs (one source of truth; no
//         re-implementation). Usage:
//           swift run cue-zone-export <overpass.json> [-o out.geojson]
//                                     [--custom-zones <zones.geojson>]
//           swift run cue-zone-export --segments <cache-dir> [-o out.geojson]
//                                     [--custom-zones <zones.geojson>]
//         --segments reads a phone's region cache (SegmentStore's manifest +
//         segments.json) in place of the extract — same [RoadSegment], no
//         Overpass round-trip and no bbox disclosure. See cue-events-export.
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
var segmentCachePath: String?
if let flagIndex = arguments.firstIndex(of: "--custom-zones") {
    guard flagIndex + 1 < arguments.count else { fail("--custom-zones requires a path") }
    customZonesPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
if let flagIndex = arguments.firstIndex(of: "--segments") {
    guard flagIndex + 1 < arguments.count else { fail("--segments requires a path") }
    segmentCachePath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
var outputPath: String?
if let flagIndex = arguments.firstIndex(of: "-o") {
    guard flagIndex + 1 < arguments.count else { fail("-o requires a path") }
    outputPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
// Exactly one segment source: the positional extract, or --segments.
guard arguments.count == (segmentCachePath == nil ? 1 : 0) else {
    fail("""
    usage: cue-zone-export <overpass.json> [-o out.geojson] [--custom-zones <zones.geojson>]
           cue-zone-export --segments <cache-dir> [-o out.geojson] [--custom-zones <zones.geojson>]
    """)
}
// Default output sits beside whichever input was given.
let inputURL = URL(fileURLWithPath: segmentCachePath ?? arguments[0])
let outputURL = outputPath.map(URL.init(fileURLWithPath:))
    ?? (segmentCachePath == nil ? inputURL.deletingLastPathComponent() : inputURL)
        .appendingPathComponent("squeeze-zones.geojson")

do {
    let segments: [RoadSegment]
    // Ways are an extract-only concept; the cache stores derived segments
    // and never saw the ways they came from.
    var waysStage = ""
    if segmentCachePath != nil {
        // SegmentStore.load validates the manifest's schema version and
        // segment count, so a truncated cache fails here rather than
        // silently scoring a partial region.
        guard let (manifest, cached) = try SegmentStore.load(
            from: URL(fileURLWithPath: inputURL.path, isDirectory: true)) else {
            fail("error: no segment cache in \(inputURL.path) (manifest.json absent)")
        }
        segments = cached
        print("segments: \(cached.count) from cache "
            + "(source sha256 \(manifest.sourceSHA256.prefix(12)))")
    } else {
        let extract = try OverpassExtract(data: Data(contentsOf: inputURL))
        segments = try SegmentImporter.deriveSegments(from: extract)
        waysStage = "\(extract.ways.count) ways -> "
    }
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
        // Per zone, say whether it will actually do anything and why not.
        // "My zone does nothing" has several causes with different remedies,
        // and the summary counts alone cannot tell them apart (#38).
        let coverage = SqueezeScorer.ridingSpaceTagCoverage(byClass: segments)
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for zoneID in match.matches.keys.sorted() {
            for segmentID in (match.matches[zoneID] ?? [:]).keys.sorted() {
                guard let segment = byID[segmentID] else { continue }
                let why = SqueezeScorer.rejectionReason(segment, coverage: coverage,
                                                        riderAsserted: true)
                let road = segment.attributes.name ?? "(unnamed)"
                print("  zone \(zoneID.prefix(8)) -> segment \(segmentID) (\(road)): "
                    + (why.map { "INERT — \($0)" } ?? "scores"))
            }
        }
    }
    let zones = SqueezeScorer.scoreZones(from: segments, riderAsserted: riderAsserted)
    let geojson = try ZoneGeoJSON.encode(zones: zones, segments: segments)
    try geojson.write(to: outputURL, options: .atomic)
    let members = zones.reduce(0) { $0 + $1.segmentIDs.count }
    print("""
    \(waysStage)\(segments.count) segments -> \
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
