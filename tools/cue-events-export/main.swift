// Intent: CLI companion to webmap.dev#231 — join a schema-v1 ride trace,
//         an optional dispatch-latency sidecar, and an Overpass `out geom;`
//         extract into the cue-events overlay GeoJSON, resolving each
//         event's segment_id to geometry through the SAME importer the app
//         runs (one source of truth; no re-implementation). Usage:
//           swift run cue-events-export <trace.json> <overpass.json> \
//             [--latency <sidecar.json>] [--strict] [-o out.geojson]
//         An event whose segment has no match in the extract is skipped
//         with a stderr warning and counted in the summary; --strict makes
//         any skip fatal (exit 1, nothing written). When the trace carries
//         GPS fixes (debug-GPS toggle, #110) the export automatically adds
//         the ride track and exact event positions (webmap.dev#236) — no
//         flag: the rider already opted in by enabling the toggle, and a
//         trace without GPS produces byte-identical output to before.
// Privacy: input and output both reveal actual ride locations (NFR-005) —
//          keep them off git. The default output lands in the TRACE FILE'S
//          directory (a CWD-relative trace resolves to the CWD, which may
//          be the repo); the *.geojson gitignore entry is the guard that
//          actually keeps ride data out of git either way.
import CueMapImport
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usage = """
usage: cue-events-export <trace.json> <overpass.json> \
[--latency <sidecar.json>] [--strict] [-o out.geojson]
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var outputPath: String?
var latencyPath: String?
var strict = false
if let flagIndex = arguments.firstIndex(of: "-o") {
    guard flagIndex + 1 < arguments.count else { fail("-o requires a path") }
    outputPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
if let flagIndex = arguments.firstIndex(of: "--latency") {
    guard flagIndex + 1 < arguments.count else { fail("--latency requires a path") }
    latencyPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
if let flagIndex = arguments.firstIndex(of: "--strict") {
    strict = true
    arguments.remove(at: flagIndex)
}
guard arguments.count == 2 else { fail(usage) }
let traceURL = URL(fileURLWithPath: arguments[0])
let extractURL = URL(fileURLWithPath: arguments[1])
let outputURL = outputPath.map(URL.init(fileURLWithPath:))
    ?? traceURL.deletingLastPathComponent()
        .appendingPathComponent("cue-events.geojson")

do {
    let trace = try CueEventGeoJSON.decodeTrace(Data(contentsOf: traceURL))
    let extract = try OverpassExtract(data: Data(contentsOf: extractURL))
    let segments = try SegmentImporter.deriveSegments(from: extract)
    let latency = try latencyPath.map {
        try CueEventGeoJSON.decodeLatencySidecar(
            Data(contentsOf: URL(fileURLWithPath: $0)))
    } ?? [:]
    let (geojson, summary) = try CueEventGeoJSON.encode(
        trace: trace, latencyByEventID: latency, segments: segments)
    // Two distinct skip causes, reported separately: a truncated trace
    // and a stale extract need opposite fixes.
    var warnings: [String] = []
    if summary.skippedNoEvidence > 0 {
        warnings.append("""
        warning: \(summary.skippedNoEvidence) cue(s) had no route-event \
        observation for their event_id (truncated or malformed trace)
        """)
    }
    if summary.skippedNoSegment > 0 {
        warnings.append("""
        warning: \(summary.skippedNoSegment) event(s) had no matching segment \
        in the extract (wrong region, or OSM edits changed segment ids)
        """)
    }
    if !warnings.isEmpty {
        let message = warnings.joined(separator: "\n")
        if strict { fail(message + "\n--strict: nothing written") }
        warn(message)
    }
    try geojson.write(to: outputURL, options: .atomic)
    print("""
    \(summary.cuesIn) HEAD_UP cue(s) + \(summary.markersIn) marker(s) in -> \
    \(summary.cueFeatures + summary.markerFeatures) feature(s) \
    (\(summary.cueFeatures) cues, \(summary.markerFeatures) markers)
    graded: \(summary.gradedCues)/\(summary.cueFeatures) cues; \
    latency join: \(summary.latencyJoins)/\(summary.cueFeatures) cues\
    \(latencyPath == nil ? " (no sidecar given)" : "")
    gps: \(summary.samplesWithFix)/\(summary.samplesIn) samples, \
    \(summary.trackEmitted ? "track emitted" : "no track"), \
    \(summary.exactCues)/\(summary.cueFeatures) cues exact, \
    \(summary.exactMarkers)/\(summary.markerFeatures) markers exact
    wrote \(outputURL.path)
    """)
} catch {
    fail("error: \(error)")
}
