// Intent: CLI companion to webmap.dev#239 — merge the grading UI's
//         reviews sidecar ("Export reviews" download) into a schema-v1
//         ride trace's reviews[] (FR-008), keeping the trace the single
//         source of truth for replay and tuning. Usage:
//           swift run cue-review-merge <trace.json> <reviews.json> [-o out.json]
//         Default output updates the trace IN PLACE (it lives in the
//         gitignored rides/ directory); -o writes elsewhere. Overwrite
//         semantics, latest wins; an unknown event id (wrong ride's
//         sidecar), malformed input, or an out-of-spec outcome fails the
//         whole merge — the atomic write means nothing partial ever
//         lands, even in place.
// Privacy: traces reveal actual ride locations by segment id (NFR-005) —
//          both input and output stay off git (/rides/ is gitignored).
import CueMapImport
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: cue-review-merge <trace.json> <reviews.json> [-o out.json]"

var arguments = Array(CommandLine.arguments.dropFirst())
var outputPath: String?
if let flagIndex = arguments.firstIndex(of: "-o") {
    guard flagIndex + 1 < arguments.count else { fail("-o requires a path") }
    outputPath = arguments[flagIndex + 1]
    arguments.removeSubrange(flagIndex...(flagIndex + 1))
}
guard arguments.count == 2 else { fail(usage) }
let traceURL = URL(fileURLWithPath: arguments[0])
let sidecarURL = URL(fileURLWithPath: arguments[1])
let outputURL = outputPath.map(URL.init(fileURLWithPath:)) ?? traceURL

do {
    let (merged, summary) = try CueReviewMerge.merge(
        trace: Data(contentsOf: traceURL),
        sidecar: Data(contentsOf: sidecarURL))
    try merged.write(to: outputURL, options: .atomic)
    print("""
    merged \(summary.merged) review(s) (\(summary.added) new, \
    \(summary.overwrote) overwrote) -> \(outputURL.path)
    """)
} catch {
    fail("error: \(error)")
}
