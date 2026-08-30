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
//         A DIRECTIONAL zone (cue#30) is applied only on samples whose course
//         says the rider was travelling its way; a trace with no
//         heading_deg_x10 cannot be gated, so those zones fall back to
//         applying both ways and the affected sample count is reported.
//         --strict refuses such a trace instead, the same escape hatch
//         cue-events-export offers for skipped events.
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
    usage: cue-custom-zone-merge <trace.json> <custom-zones.geojson> <region.json> [-o out.json] [--strict]
    WARNING: without -o, <trace.json> is overwritten in place (rides/ is gitignored — no easy undo).
    --strict: fail instead of applying a directional zone both ways on samples the trace cannot gate.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var strict = false
if let flagIndex = arguments.firstIndex(of: "--strict") {
    strict = true
    arguments.remove(at: flagIndex)
}
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
    var warnings: [String] = []
    if summary.ungatedSamples > 0 {
        warnings.append("""
        \(summary.ungatedSamples) sample(s) carried no heading_deg_x10, so directional zone(s) \
        were applied in BOTH directions there — this what-if overstates them by however much \
        the reverse passes contribute. Re-record with the debug-GPS toggle on for a gated answer.
        """)
    }
    if summary.undirectedSegments > 0 {
        // Deliberately NOT folded into the line above: re-recording is the
        // fix for a missing course and no fix at all for a segment whose
        // geometry has no direction to compare against.
        warnings.append("""
        \(summary.undirectedSegments) matched segment(s) have no usable bearing (coincident \
        nodes in the region extract), so directional zone(s) there were applied in BOTH \
        directions — re-recording cannot change this; the region extract would have to.
        """)
    }
    if !warnings.isEmpty {
        let detail = warnings.joined(separator: "\n")
        if strict { fail("error: " + detail) }
        FileHandle.standardError.write(Data(("warning: " + detail + "\n").utf8))
    }
    try merged.write(to: outputURL, options: .atomic)
    print("""
    \(summary.zonesMatched) zone(s) matched -> \(summary.segmentsMatched) segment(s) \
    (\(summary.zonesUnmatched) zone(s) unmatched), \(summary.changePoints) personal_memory \
    change point(s), \(summary.ungatedSamples) ungated sample(s), \
    \(summary.undirectedSegments) bearingless segment(s) -> \(outputURL.path)
    """)
} catch {
    fail("error: \(error)")
}
