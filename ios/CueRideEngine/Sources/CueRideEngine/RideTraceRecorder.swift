// Intent: Schema-v2 trace recording and export (RFC 0003, FR-009/FR-010;
//         RFC 0002 D6): every sample, observation, decision, and personal-
//         memory carry-forward change point of a ride, serialized to the
//         exact interchange format replay_cli consumes — so the ride
//         replays deterministically through the same kernel (NFR-003). A
//         live decision personal route memory influenced that the trace
//         couldn't reproduce would itself be an NFR-003 violation, so
//         schema_version is always 2 now that resolveMemory can bias
//         cueing — personal_memory[] is simply empty on a ride where the
//         store never resolved anything (a fresh store, or no history yet
//         on any ridden segment).
// Privacy: The default export is the POLICY-TUNING trace: no lat_e7/lon_e7
//          anywhere (NFR-005 — the kernel replays from t_ms, speed_cmps,
//          and segment_id alone). Full-GPS export is a separate DEBUG call
//          for map-matching inspection on the operator's own machine.
// Pattern: Field names and integer widths mirror replay_trace.schema.json /
//          kernel/cue_policy.h. sortedKeys encoding keeps exports
//          byte-stable for a given ride (same convention as SegmentStore).
import CueKernel
import Foundation

/// After-ride outcome per cue (FR-008). Raw values are the schema's
/// `Review.outcome` enum verbatim — the trace is the interchange contract,
/// so these strings must never drift from replay_trace.schema.json.
public enum ReviewOutcome: String, CaseIterable, Sendable {
    case useful
    case falseAlarm = "false_alarm"
    case tooLate = "too_late"
    /// A cue fired so far ahead that the warning felt disconnected from
    /// the hazard by the time the rider reached it — the timing failure
    /// opposite `.tooLate`.
    case tooEarly = "too_early"
    /// A cue fired, but the rider never noticed it (as opposed to
    /// `.tooLate`, where the rider noticed but too late to react).
    case unrecognized
}

/// Accumulates one ride's records and exports the schema-v1 JSON trace.
public final class RideTraceRecorder {
    struct Record {
        let sample: RideSample
        let events: [RouteEvent]
        let decision: CueDecision
        /// False when the fix carried no course: the export then omits
        /// heading_deg_x10 (schema-optional) so "unknown" is never
        /// conflated with "due north".
        let headingKnown: Bool
    }

    public let rideID: String
    public let startedAt: String
    /// GPS retention is opt-in per ride (NFR-005: store only what cue
    /// tuning and replay need). When false — the default — coordinates
    /// are zeroed at record time, so they never sit in memory for the
    /// ride, and the debug export has nothing to reveal.
    public let retainGPS: Bool
    private let config: CuePolicyConfig
    private(set) var records: [Record] = []
    private(set) var markers: [MarkerRecord] = []
    /// Keyed by event id: the schema allows ONE review per reviewed cue,
    /// so re-grading replaces rather than appends.
    private var reviewsByEventID: [UInt32: ReviewEntry] = [:]
    /// Carry-forward change points (RFC 0002 D6): one entry only when the
    /// resolved memory actually CHANGES from the previous sample — logging
    /// every sample would defeat the point of carry-forward and bloat the
    /// trace for no reason (memory changes far more rarely than samples).
    private(set) var personalMemoryChangePoints: [PersonalMemoryChangePoint] = []
    /// The canonical "no memory" tuple — matches resolveMemory returning
    /// nil and is what a fresh ride starts from, so the FIRST sample only
    /// logs a change point if memory is ALREADY active on it.
    private var lastLoggedMemory: (segmentID: UInt32, state: PersonalMemoryState, noticeBonusS: UInt8) =
        (0, .neutral, 0)

    struct MarkerRecord {
        let tMs: UInt32
        let segmentID: UInt32
        let latE7: Int32?
        let lonE7: Int32?
    }

    struct PersonalMemoryChangePoint {
        let tMs: UInt32
        let segmentID: UInt32
        let state: PersonalMemoryState
        let noticeBonusS: UInt8
    }

    private struct ReviewEntry {
        let outcome: ReviewOutcome
        let reviewedAt: String?
    }

    /// `startedAt` is the wall-clock ride start, ISO 8601 UTC — the caller
    /// formats it so tests and exports stay deterministic.
    public init(rideID: String, startedAt: String, config: CuePolicyConfig,
                retainGPS: Bool = false) {
        self.rideID = rideID
        self.startedAt = startedAt
        self.config = config
        self.retainGPS = retainGPS
    }

    func record(sample: RideSample, events: [RouteEvent], decision: CueDecision,
                headingKnown: Bool, resolvedMemory: ResolvedPersonalMemory?) {
        var sample = sample
        if !retainGPS {
            sample.lat_e7 = 0
            sample.lon_e7 = 0
        }
        records.append(Record(sample: sample, events: events, decision: decision,
                              headingKnown: headingKnown))
        let current: (segmentID: UInt32, state: PersonalMemoryState, noticeBonusS: UInt8)
        if let resolvedMemory {
            current = (resolvedMemory.segmentID, resolvedMemory.state, resolvedMemory.noticeBonusS)
        } else if lastLoggedMemory.segmentID != 0 {
            // Clearing an active record: keep ITS segment_id rather than
            // writing the reserved sentinel 0 — replay_main.c's decoder
            // rejects segment_id == 0 outright (RFC 0002 D5), and the
            // kernel only needs state == NEUTRAL to stop applying it.
            current = (lastLoggedMemory.segmentID, .neutral, 0)
        } else {
            current = (0, .neutral, 0)
        }
        if current != lastLoggedMemory {
            personalMemoryChangePoints.append(PersonalMemoryChangePoint(
                tMs: sample.t_ms, segmentID: current.segmentID,
                state: current.state, noticeBonusS: current.noticeBonusS))
            lastLoggedMemory = current
        }
    }

    /// One rider marker (FR-006). Heading and speed are deliberately NOT
    /// duplicated here — they are recoverable from the collocated sample
    /// at the marker's t_ms (D5); GPS follows the same retention opt-in
    /// as samples (NFR-005).
    func recordMarker(tMs: UInt32, segmentID: UInt32, latE7: Int32, lonE7: Int32) {
        markers.append(MarkerRecord(
            tMs: tMs, segmentID: segmentID,
            latE7: retainGPS ? latE7 : nil,
            lonE7: retainGPS ? lonE7 : nil))
    }

    /// The segment_id an event_id was observed on this ride (RFC 0002 D1:
    /// reviews attribute to a segment by joining event_id to the
    /// RouteEvent.segment_id observed for it). A RouteEvent's segment_id is
    /// fixed per event/zone across every observation, so the first match
    /// is authoritative. nil if the event was never observed — reviews
    /// name event ids from rider-facing UI state, not a trusted index, so
    /// this must tolerate a miss rather than assume one always exists.
    func segmentID(forEventID eventID: UInt32) -> UInt32? {
        for record in records {
            if let event = record.events.first(where: { $0.event_id == eventID }) {
                return event.segment_id
            }
        }
        return nil
    }

    /// One after-ride review (FR-008, RFC 0003 D7). Re-grading the same
    /// event REPLACES the prior review — the schema records one outcome
    /// per reviewed cue, and the rider's latest judgment wins. `reviewedAt`
    /// is caller-formatted ISO 8601 UTC — the same convention as
    /// `startedAt`, so exports stay deterministic under test.
    public func addReview(eventID: UInt32, outcome: ReviewOutcome,
                          reviewedAt: String? = nil) {
        reviewsByEventID[eventID] = ReviewEntry(outcome: outcome,
                                                reviewedAt: reviewedAt)
    }

    /// HEAD_UP decisions in chronological order — the rows the review UI
    /// grades. Records are appended in sample order, so no re-sort.
    public var cueSummaries: [(tMs: UInt32, eventID: UInt32)] {
        records.filter { $0.decision.isHeadUp }
            .map { (tMs: $0.sample.t_ms, eventID: $0.decision.event_id) }
    }

    /// Rider markers in chronological order (a queued watch marker can be
    /// RECORDED after later phone-side marks — same re-sort as the export).
    public var markerSummaries: [(tMs: UInt32, segmentID: UInt32)] {
        markers.sorted { $0.tMs < $1.tMs }
            .map { (tMs: $0.tMs, segmentID: $0.segmentID) }
    }

    /// The default export: policy-tuning trace, no GPS fields (NFR-005).
    public func exportPolicyTrace() throws -> Data {
        try export(includeGPS: false)
    }

    /// Debug export with lat/lon per sample — map-matching inspection only;
    /// intended for the operator's own machine, never for sharing. Carries
    /// GPS keys only when the ride was recorded with `retainGPS: true`;
    /// otherwise it is identical to the policy export (nothing was kept).
    public func exportDebugTrace() throws -> Data {
        try export(includeGPS: retainGPS)
    }

    private func export(includeGPS: Bool) throws -> Data {
        let trace = Trace(
            schema_version: 2,
            ride_id: rideID,
            started_at: startedAt,
            policy_config: .init(
                severity_threshold: config.severity_threshold,
                confidence_threshold: config.confidence_threshold,
                min_notice_s: config.min_notice_s,
                max_notice_s: config.max_notice_s,
                min_cooldown_s: config.min_cooldown_s,
                min_cooldown_m: config.min_cooldown_m,
                min_speed_kmh: config.min_speed_kmh),
            samples: records.map { record in
                Sample(
                    t_ms: record.sample.t_ms,
                    lat_e7: includeGPS ? record.sample.lat_e7 : nil,
                    lon_e7: includeGPS ? record.sample.lon_e7 : nil,
                    speed_cmps: record.sample.speed_cmps,
                    heading_deg_x10: record.headingKnown
                        ? record.sample.heading_deg_x10 : nil,
                    segment_id: record.sample.segment_id)
            },
            route_events: records.flatMap { record in
                record.events.map { event in
                    Observation(
                        t_ms: record.sample.t_ms,
                        event_id: event.event_id,
                        family: "COMPOSITE_SQUEEZE_ZONE",
                        segment_id: event.segment_id,
                        severity: event.severity,
                        confidence: event.confidence,
                        reasons_bitmask: event.reasons_bitmask,
                        distance_to_start_m: event.distance_to_start_m,
                        distance_to_end_m: event.distance_to_end_m)
                }
            },
            // Every decision is logged, suppressed ones included — the
            // schema requires HEAD_UPs and says NONE records aid §13 tuning.
            cue_decisions: records.map { record in
                Decision(
                    t_ms: record.sample.t_ms,
                    type: record.decision.isHeadUp ? "HEAD_UP" : "NONE",
                    event_id: record.decision.event_id,
                    reason_code: record.decision.reason_code,
                    lead_time_s: record.decision.lead_time_s)
            },
            // Chronological, not delivery, order: a queued watch marker
            // can arrive after later phone-side marks were recorded.
            markers: markers.sorted { $0.tMs < $1.tMs }.map { marker in
                Marker(t_ms: marker.tMs,
                       lat_e7: includeGPS ? marker.latE7 : nil,
                       lon_e7: includeGPS ? marker.lonE7 : nil,
                       segment_id: marker.segmentID,
                       type: "unsafe_here")
            },
            // event_id order, not grading order: dictionary iteration is
            // unstable, and byte-stable exports are the file's contract.
            reviews: reviewsByEventID.sorted { $0.key < $1.key }.map { id, entry in
                Review(event_id: id,
                       outcome: entry.outcome.rawValue,
                       reviewed_at: entry.reviewedAt)
            },
            // Recorded in sample order already (appended as the ride
            // progressed) — no re-sort needed, unlike markers/reviews above.
            // Deliberately NOT appending a synthetic terminal clear record
            // when the ride ends memory-active: carry-forward records take
            // effect INCLUSIVE of their own t_ms (replay_main.c applies a
            // record to the very sample stamped with its timestamp, before
            // that sample's kernel step). A clear record stamped at the
            // ride's own last sample would make THAT sample replay under
            // NEUTRAL memory even though it was decided live under
            // whatever was actually active — the exact live/replay
            // divergence this export exists to prevent, just reintroduced
            // at the other end. There is no valid later timestamp to stamp
            // a clear into (replay's trace-shape validation requires every
            // personal_memory[] t_ms to match a real sample). A trace
            // ending non-neutral is expected whenever the ride ends while
            // memory is active; the replay harness warns on it (advisory),
            // it does not fail.
            personal_memory: personalMemoryChangePoints.map { point in
                PersonalMemory(t_ms: point.tMs, segment_id: point.segmentID,
                              state: point.state.schemaName,
                              notice_bonus_s: point.noticeBonusS)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // byte-stable exports
        return try encoder.encode(trace)
    }

    // MARK: - Schema-v1 shapes (names mirror replay_trace.schema.json)

    private struct Trace: Encodable {
        let schema_version: Int
        let ride_id: String
        let started_at: String
        let policy_config: Config
        let samples: [Sample]
        let route_events: [Observation]
        let cue_decisions: [Decision]
        let markers: [Marker]
        let reviews: [Review]
        let personal_memory: [PersonalMemory]
    }

    private struct Config: Encodable {
        let severity_threshold: UInt8
        let confidence_threshold: UInt8
        let min_notice_s: UInt16
        let max_notice_s: UInt16
        let min_cooldown_s: UInt16
        let min_cooldown_m: UInt16
        let min_speed_kmh: UInt16
    }

    private struct Sample: Encodable {
        let t_ms: UInt32
        let lat_e7: Int32?
        let lon_e7: Int32?
        let speed_cmps: UInt16
        /// nil = no course from the receiver; the key is omitted so
        /// "unknown" never reads as "due north". replay_cli's opt_u16
        /// defaults the absent key to 0 — the value the kernel saw live.
        let heading_deg_x10: UInt16?
        let segment_id: UInt32

        enum CodingKeys: String, CodingKey {
            case t_ms, lat_e7, lon_e7, speed_cmps, heading_deg_x10, segment_id
        }

        // encodeIfPresent so optional fields carry no keys at all (NFR-005
        // for GPS; unknown-course for heading), rather than nulls the
        // schema would reject.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t_ms, forKey: .t_ms)
            try container.encodeIfPresent(lat_e7, forKey: .lat_e7)
            try container.encodeIfPresent(lon_e7, forKey: .lon_e7)
            try container.encode(speed_cmps, forKey: .speed_cmps)
            try container.encodeIfPresent(heading_deg_x10, forKey: .heading_deg_x10)
            try container.encode(segment_id, forKey: .segment_id)
        }
    }

    private struct Observation: Encodable {
        let t_ms: UInt32
        let event_id: UInt32
        let family: String
        let segment_id: UInt32
        let severity: UInt8
        let confidence: UInt8
        let reasons_bitmask: UInt16
        let distance_to_start_m: Int16
        let distance_to_end_m: Int16
    }

    private struct Decision: Encodable {
        let t_ms: UInt32
        let type: String
        let event_id: UInt32
        let reason_code: UInt8
        let lead_time_s: Int16
    }

    private struct Marker: Encodable {
        let t_ms: UInt32
        let lat_e7: Int32?
        let lon_e7: Int32?
        let segment_id: UInt32
        let type: String

        enum CodingKeys: String, CodingKey {
            case t_ms, lat_e7, lon_e7, segment_id, type
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t_ms, forKey: .t_ms)
            try container.encodeIfPresent(lat_e7, forKey: .lat_e7)
            try container.encodeIfPresent(lon_e7, forKey: .lon_e7)
            try container.encode(segment_id, forKey: .segment_id)
            try container.encode(type, forKey: .type)
        }
    }

    private struct Review: Encodable {
        let event_id: UInt32
        let outcome: String
        /// nil = the caller supplied no submission time; the key is omitted
        /// (schema-optional) rather than encoded as a null it would reject.
        let reviewed_at: String?

        enum CodingKeys: String, CodingKey {
            case event_id, outcome, reviewed_at
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(event_id, forKey: .event_id)
            try container.encode(outcome, forKey: .outcome)
            try container.encodeIfPresent(reviewed_at, forKey: .reviewed_at)
        }
    }

    private struct PersonalMemory: Encodable {
        let t_ms: UInt32
        let segment_id: UInt32
        let state: String
        let notice_bonus_s: UInt8
    }
}

extension PersonalMemoryState {
    /// The schema's string enum (replay_trace.schema.json PersonalMemoryRecord.state) —
    /// must never drift from NEUTRAL/UNSAFE/SUPPRESS.
    var schemaName: String {
        switch self {
        case .neutral: return "NEUTRAL"
        case .unsafe: return "UNSAFE"
        case .suppress: return "SUPPRESS"
        }
    }
}
