// Intent: CLI companion to the app's "Import custom zones…" action —
//         merge webmap.dev's custom-zones GeoJSON export into a replay
//         trace's personal_memory[] (RFC 0002 D6), so a rider-drawn zone
//         can be tuned against a recorded ride without needing a live ride
//         on the phone. Usage:
//           swift run cue-custom-zone-merge <trace.json> <custom-zones.geojson> <region.json> [-o out.json]
//         Default output updates the trace IN PLACE (it lives in the
//         gitignored rides/ directory); -o writes elsewhere. This REPLACES
//         the trace's personal_memory[] with what the custom zones resolve
//         to (a what-if merge, not an additive one — see CueCustomZoneMerge).
// Privacy: traces and region extracts both reveal ride locations by
//          segment id (NFR-005) — all three inputs and the output stay off
//          git (/rides/, *.geojson, /region.json are gitignored).
import CueMapImport
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
    usage: cue-custom-zone-merge <trace.json> <custom-zones.geojson> <region.json> [-o out.json]
    WARNING: without -o, <trace.json> is overwritten in place (rides/ is gitignored — no easy undo).
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var outputPath: String?
if let flagIndex = arguments.firstIndex(of: "-o") {
    guard flagIndex + 1 < arguments.count else { fail("-o requires a path") }
    outputPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
guard arguments.count == 3 else { fail(usage) }
let traceURL = URL(fileURLWithPath: arguments[0])
let customZonesURL = URL(fileURLWithPath: arguments[1])
let regionURL = URL(fileURLWithPath: arguments[2])
let outputURL = outputPath.map(URL.init(fileURLWithPath:)) ?? traceURL

do {
    let (merged, summary) = try CueCustomZoneMerge.merge(
        trace: Data(contentsOf: traceURL),
        customZones: Data(contentsOf: customZonesURL),
        region: Data(contentsOf: regionURL))
    try merged.write(to: outputURL, options: .atomic)
    print("""
    \(summary.zonesMatched) zone(s) matched -> \(summary.segmentsMatched) segment(s) \
    (\(summary.zonesUnmatched) zone(s) unmatched), \(summary.changePoints) personal_memory \
    change point(s) -> \(outputURL.path)
    """)
} catch {
    fail("error: \(error)")
}
