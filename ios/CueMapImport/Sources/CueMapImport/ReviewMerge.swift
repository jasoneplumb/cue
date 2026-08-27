// Intent: Merge a map-grading reviews sidecar (webmap.dev#239's "Export
//         reviews" download) into a schema-v1 or v2 ride trace's reviews[]
//         (FR-008) — the trace stays the single source of truth, so
//         replay and tuning tooling see the grades with zero changes.
//         Semantics: overwrite, latest wins — an incoming review replaces
//         any existing review for its event_id (in place, duplicates
//         collapsed); untouched reviews are preserved; genuinely new
//         reviews append in sidecar order. All-or-nothing: every incoming
//         event_id must match a HEAD_UP decision in the trace (an unknown
//         id means the wrong ride's sidecar — the likeliest user mistake)
//         and every outcome must be schema-valid, or the merge throws and
//         nothing is produced.
// Pattern: The trace re-encodes through JSONSerialization with sortedKeys
//          — the same deterministic byte contract as RideTraceRecorder's
//          exports — so everything outside reviews[] is preserved
//          value-for-value (the schema is integers and strings only; no
//          floats to reformat) and re-merging the same sidecar is
//          byte-idempotent.
import Foundation

public enum CueReviewMergeError: Error, Equatable, CustomStringConvertible {
    /// Trace schema is versioned; refuse unknown versions rather than
    /// silently misreading fields (same stance as replay_cli).
    case unsupportedSchemaVersion(Int)
    case malformedTrace(String)
    case malformedSidecar(String)
    /// An outcome outside the schema's Review.outcome enum (FR-008).
    case invalidOutcome(eventID: UInt32, outcome: String)
    /// Incoming event ids with no HEAD_UP decision in the trace — the
    /// sidecar grades a different ride.
    case unknownEventIDs([UInt32])

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "trace schema_version \(version) is not supported (expected 1 or 2)"
        case .malformedTrace(let reason):
            return "malformed trace: \(reason)"
        case .malformedSidecar(let reason):
            return """
            malformed reviews sidecar: \(reason) — expected a JSON array of \
            {"event_id", "outcome", "reviewed_at"} objects
            """
        case .invalidOutcome(let eventID, let outcome):
            return """
            invalid outcome "\(outcome)" for event \(eventID) — expected one \
            of: useful, false_alarm, too_late, too_early, unrecognized
            """
        case .unknownEventIDs(let ids):
            return """
            \(ids.count) review(s) reference event id(s) with no HEAD_UP cue \
            in this trace: \(ids.map(String.init).joined(separator: ", ")) — \
            wrong ride's sidecar? Nothing was merged.
            """
        }
    }
}

public enum CueReviewMerge {
    /// Trace schema versions this merge can read. v1 predates personal
    /// route memory; v2 (RFC 0002 D6) adds personal_memory[], a field
    /// this tool neither reads nor rewrites. Every trace the phone has
    /// recorded since RideTraceRecorder started stamping 2 is a v2 trace,
    /// so refusing it stranded the whole grading round trip. References
    /// `CueEventGeoJSON.supportedSchemaVersions` so both halves of the
    /// grading round trip always accept the same trace versions.
    public static let supportedSchemaVersions: Set<Int> =
        CueEventGeoJSON.supportedSchemaVersions

    /// What the merge did — the CLI's one-line report.
    public struct Summary: Equatable, Sendable {
        /// Distinct incoming event ids applied (added + overwrote).
        public let merged: Int
        /// Incoming reviews for event ids the trace had no review for.
        public let added: Int
        /// Incoming reviews that replaced an existing review.
        public let overwrote: Int
    }

    /// One sidecar entry. `reviewed_at` is optional in the schema and
    /// passed through verbatim when present; unknown keys are dropped so
    /// the output stays schema-valid (Review forbids extra properties).
    private struct IncomingReview: Decodable {
        let event_id: UInt32
        let outcome: String
        let reviewed_at: String?
    }

    /// Merge the sidecar's reviews into the trace's reviews[] and return
    /// the re-encoded trace. Throws before producing anything on the
    /// first validation failure — never a partial merge.
    public static func merge(trace traceData: Data,
                             sidecar sidecarData: Data) throws -> (trace: Data, summary: Summary) {
        // Sidecar first: strict types via Codable (event_id must fit
        // uint32, outcome/reviewed_at must be strings).
        let rawIncoming: [IncomingReview]
        do {
            rawIncoming = try JSONDecoder().decode([IncomingReview].self,
                                                   from: sidecarData)
        } catch {
            throw CueReviewMergeError.malformedSidecar(String(describing: error))
        }
        // Latest wins WITHIN the sidecar too: last entry per event id,
        // kept in first-appearance order (deterministic append order).
        var incomingOrder: [UInt32] = []
        var incomingByID: [UInt32: IncomingReview] = [:]
        for review in rawIncoming {
            guard CueEventGeoJSON.validOutcomes.contains(review.outcome) else {
                throw CueReviewMergeError.invalidOutcome(
                    eventID: review.event_id, outcome: review.outcome)
            }
            if incomingByID[review.event_id] == nil {
                incomingOrder.append(review.event_id)
            }
            incomingByID[review.event_id] = review
        }

        // Trace via JSONSerialization so every field outside reviews[] —
        // known or future — round-trips untouched. Thread the Foundation
        // error through (same pattern as the sidecar path) so a corrupt or
        // truncated trace reports the actual syntax problem, not just
        // "not a JSON object".
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: traceData)
        } catch {
            throw CueReviewMergeError.malformedTrace(String(describing: error))
        }
        guard let root = jsonObject as? [String: Any] else {
            throw CueReviewMergeError.malformedTrace("not a JSON object")
        }
        guard let version = root["schema_version"] as? Int else {
            throw CueReviewMergeError.malformedTrace("missing schema_version")
        }
        // v2 adds personal_memory[] (RFC 0002 D6), which this merge never
        // reads — it rewrites reviews[] and round-trips every other field
        // through JSONSerialization untouched. So both versions are safe
        // here; the guard exists to refuse a FUTURE version that might
        // restructure cue_decisions or reviews out from under us.
        guard CueReviewMerge.supportedSchemaVersions.contains(version) else {
            throw CueReviewMergeError.unsupportedSchemaVersion(version)
        }
        guard let decisions = root["cue_decisions"] as? [[String: Any]] else {
            throw CueReviewMergeError.malformedTrace(
                "missing or non-array cue_decisions")
        }
        var headUpIDs = Set<UInt32>()
        for decision in decisions where decision["type"] as? String == "HEAD_UP" {
            if let id = (decision["event_id"] as? NSNumber)
                .flatMap(UInt32.init(exactly:)) {
                headUpIDs.insert(id)
            }
        }
        let unknown = incomingOrder.filter { !headUpIDs.contains($0) }
        guard unknown.isEmpty else {
            throw CueReviewMergeError.unknownEventIDs(unknown.sorted())
        }
        // The schema requires reviews[], but a producer that omitted it
        // is repaired, not rejected — the merge's output restores schema
        // validity either way. Present-but-wrong-shape is still malformed.
        let existing: [[String: Any]]
        if let value = root["reviews"] {
            guard let array = value as? [[String: Any]] else {
                throw CueReviewMergeError.malformedTrace(
                    "reviews is not an array of objects")
            }
            existing = array
        } else {
            existing = []
        }

        // Overwrite in place (first occurrence takes the incoming review;
        // duplicate existing reviews for an overwritten id collapse — one
        // review per reviewed cue, FR-008); preserve the rest verbatim;
        // append the genuinely new in sidecar order.
        func encodeReview(_ review: IncomingReview) -> [String: Any] {
            var object: [String: Any] = [
                "event_id": review.event_id,
                "outcome": review.outcome,
            ]
            if let reviewedAt = review.reviewed_at {
                object["reviewed_at"] = reviewedAt
            }
            return object
        }
        var consumed = Set<UInt32>()
        var mergedReviews: [[String: Any]] = []
        for entry in existing {
            let id = (entry["event_id"] as? NSNumber)
                .flatMap(UInt32.init(exactly:))
            if let id, let incoming = incomingByID[id] {
                if consumed.insert(id).inserted {
                    mergedReviews.append(encodeReview(incoming))
                }
                continue
            }
            mergedReviews.append(entry)
        }
        let overwrote = consumed.count
        for id in incomingOrder where !consumed.contains(id) {
            mergedReviews.append(encodeReview(incomingByID[id]!))
        }

        var output = root
        output["reviews"] = mergedReviews
        let data = try JSONSerialization.data(withJSONObject: output,
                                              options: [.sortedKeys])
        return (data, Summary(merged: incomingOrder.count,
                              added: incomingOrder.count - overwrote,
                              overwrote: overwrote))
    }
}
