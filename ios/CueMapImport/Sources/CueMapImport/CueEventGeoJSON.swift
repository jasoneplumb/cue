// Intent: GeoJSON export of one ride's cue events and rider markers for
//         map-overlay consumption (webmap.dev#231, GPS: webmap.dev#236):
//         one Point feature per fired HEAD_UP cue or rider marker, joined
//         from the schema-v1 trace, the optional dispatch-latency sidecar,
//         and the imported segment geometry. The policy trace carries no
//         GPS by default (NFR-005), so each point is its matched segment's
//         along-length midpoint, flagged `approx: true` — "somewhere on
//         this segment". When the rider enabled the debug-GPS toggle
//         (#110) the trace carries per-sample fixes: the export then adds
//         one `kind: "track"` LineString (≥ 2 fixed samples, ordered by
//         t_ms) and positions events at their GPS fix with `approx`
//         OMITTED — markers at their own fix, cues at the fix of the
//         sample nearest their t_ms within `cueFixToleranceMs`; a cue's
//         fix also contributes `heading_deg` (direction of travel,
//         degrees clockwise from north) when its sample carried a course
//         (#144). Events with no usable fix fall back to the midpoint
//         form; one file may mix both. A trace without GPS produces
//         byte-identical output to the pre-GPS export.
// Privacy: the output's coordinates ARE actual ride locations (NFR-005):
//          the file is for the operator's own map, never for the repo —
//          *.geojson is gitignored.
// Pattern: Deterministic bytes for identical inputs (sortedKeys; cues in
//          trace order, then markers in trace order), matching ZoneGeoJSON.
//          Absent optional fields are OMITTED, never null — the consumer
//          contract keys on key presence.
import Foundation

public enum CueEventExportError: Error, Equatable {
    /// Trace schema is versioned; refuse unknown versions rather than
    /// silently misreading fields (same stance as replay_cli).
    case unsupportedSchemaVersion(Int)
}

public enum CueEventGeoJSON {
    /// Trace schema versions this export can read — see the guard in
    /// `decodeTrace`. Kept in step with `CueReviewMerge`: the two halves
    /// of the grading round trip must accept the same traces, or a ride
    /// exports to the map but its grades cannot be merged back.
    public static let supportedSchemaVersions: Set<Int> = [1, 2]

    // MARK: - Decoded inputs

    /// The trace subset this export consumes: fired cues with their zone
    /// evidence and review outcome already joined, plus rider markers.
    public struct TraceEvents: Sendable {
        /// Zone evidence resolved from the cue's route-event observations.
        public struct ZoneEvidence: Equatable, Sendable {
            public let segmentID: UInt32
            public let severity: UInt8
            public let confidence: UInt8
            public let reasonsBitmask: UInt16
        }

        public struct Cue: Sendable {
            public let eventID: UInt32
            public let tMs: UInt32
            public let leadTimeS: Int16
            /// nil when the trace has no observation for this event id —
            /// the export cannot place the cue and skips it (reported).
            public let evidence: ZoneEvidence?
            /// FR-008 review grade; nil = ungraded (key omitted on export).
            public let outcome: String?
        }

        public struct Marker: Sendable {
            public let tMs: UInt32
            public let segmentID: UInt32
            /// Optional GPS fix captured with the marker (#110); the
            /// marker exports exact only when BOTH coordinates are present.
            public let latE7: Int32?
            public let lonE7: Int32?
        }

        /// One sample's GPS fix (a sample carrying both lat_e7 and
        /// lon_e7); samples without a fix never appear here.
        public struct GPSFix: Equatable, Sendable {
            public let tMs: UInt32
            public let latE7: Int32
            public let lonE7: Int32
            /// Direction of travel in tenths of a degree clockwise from
            /// north, when the fix's sample carried a course (the recorder
            /// omits heading_deg_x10 for courseless fixes so "unknown" is
            /// never conflated with "due north" — same stance here).
            public let headingDegX10: UInt16?
        }

        /// HEAD_UP decisions in trace order.
        public let cues: [Cue]
        /// Rider markers in trace order.
        public let markers: [Marker]
        /// Total samples in the trace (fixed or not) — the denominator of
        /// the summary's GPS-coverage report.
        public let sampleCount: Int
        /// GPS fixes in trace order (the schema requires strictly
        /// increasing sample t_ms, so trace order is t_ms order).
        public let gpsFixes: [GPSFix]
    }

    /// One cue's delivery facts from the latency sidecar
    /// (CueDispatcher.exportLatencyLog), keyed by event id.
    public struct LatencyEntry: Equatable, Sendable {
        public let delivered: Bool
        /// nil = unmeasured (unacked, or ack without a readable timestamp).
        public let latencyMs: UInt64?

        public init(delivered: Bool, latencyMs: UInt64?) {
            self.delivered = delivered
            self.latencyMs = latencyMs
        }
    }

    /// The schema's `Review.outcome` enum (FR-008) — must never drift
    /// from replay_trace.schema.json.
    static let validOutcomes: Set<String> = [
        "useful", "false_alarm", "too_late", "too_early", "unrecognized",
    ]

    /// Decode the trace subset from a schema-v1 or v2 ride trace
    /// (replay_trace.schema.json). Joins each HEAD_UP decision to its
    /// zone evidence (the FIRST route-event observation carrying that
    /// event id — array order, deterministic) and its FR-008 review.
    public static func decodeTrace(_ data: Data) throws -> TraceEvents {
        struct RawTrace: Decodable {
            let schema_version: Int
            let cue_decisions: [RawDecision]
            let route_events: [RawObservation]
            let markers: [RawMarker]
            let reviews: [RawReview]
            /// Optional here (though the schema requires it) so pre-GPS
            /// trace subsets keep decoding — this export never needed
            /// samples before GPS support.
            let samples: [RawSample]?
        }
        struct RawSample: Decodable {
            let t_ms: UInt32
            let lat_e7: Int32?
            let lon_e7: Int32?
            let heading_deg_x10: UInt16?
        }
        struct RawDecision: Decodable {
            let t_ms: UInt32
            let type: String
            let event_id: UInt32
            let lead_time_s: Int16
        }
        struct RawObservation: Decodable {
            let event_id: UInt32
            let segment_id: UInt32
            let severity: UInt8
            let confidence: UInt8
            let reasons_bitmask: UInt16
        }
        struct RawMarker: Decodable {
            let t_ms: UInt32
            let segment_id: UInt32
            let lat_e7: Int32?
            let lon_e7: Int32?
        }
        struct RawReview: Decodable {
            let event_id: UInt32
            let outcome: String
        }
        let raw = try JSONDecoder().decode(RawTrace.self, from: data)
        // v2 (RFC 0002 D6) only ADDS personal_memory[]; every field this
        // export reads — cue_decisions, route_events, markers, reviews,
        // samples — is unchanged from v1, and personal_memory is not one
        // of them. Refusing v2 blocked exporting any ride the phone has
        // recorded since the recorder began stamping 2.
        guard Self.supportedSchemaVersions.contains(raw.schema_version) else {
            throw CueEventExportError.unsupportedSchemaVersion(raw.schema_version)
        }
        var evidenceByEventID: [UInt32: TraceEvents.ZoneEvidence] = [:]
        for observation in raw.route_events
        where evidenceByEventID[observation.event_id] == nil {
            evidenceByEventID[observation.event_id] = TraceEvents.ZoneEvidence(
                segmentID: observation.segment_id,
                severity: observation.severity,
                confidence: observation.confidence,
                reasonsBitmask: observation.reasons_bitmask)
        }
        // The schema records one review per reviewed cue; if a producer
        // ever emits duplicates, the first wins (deterministic). An
        // out-of-spec outcome value is DROPPED — the cue exports ungraded
        // rather than feeding an unknown string to the overlay's colour
        // key (the conservative direction; the schema-version guard only
        // covers structural changes, not value drift).
        var outcomeByEventID: [UInt32: String] = [:]
        for review in raw.reviews
        where validOutcomes.contains(review.outcome)
            && outcomeByEventID[review.event_id] == nil {
            outcomeByEventID[review.event_id] = review.outcome
        }
        let samples = raw.samples ?? []
        return TraceEvents(
            cues: raw.cue_decisions.filter { $0.type == "HEAD_UP" }.map {
                TraceEvents.Cue(
                    eventID: $0.event_id,
                    tMs: $0.t_ms,
                    leadTimeS: $0.lead_time_s,
                    evidence: evidenceByEventID[$0.event_id],
                    outcome: outcomeByEventID[$0.event_id])
            },
            markers: raw.markers.map {
                TraceEvents.Marker(tMs: $0.t_ms, segmentID: $0.segment_id,
                                   latE7: $0.lat_e7, lonE7: $0.lon_e7)
            },
            sampleCount: samples.count,
            gpsFixes: samples.compactMap { sample -> TraceEvents.GPSFix? in
                guard let lat = sample.lat_e7, let lon = sample.lon_e7 else {
                    return nil
                }
                return TraceEvents.GPSFix(tMs: sample.t_ms, latE7: lat, lonE7: lon,
                                          headingDegX10: sample.heading_deg_x10)
            })
    }

    /// Decode the latency sidecar (CueDispatcher.exportLatencyLog) into a
    /// per-event join table. A duplicate event id keeps the first entry
    /// (the kernel fires at most one HEAD_UP per event — NFR-001 — so
    /// duplicates only arise from malformed sidecars).
    public static func decodeLatencySidecar(_ data: Data) throws -> [UInt32: LatencyEntry] {
        struct RawLog: Decodable {
            let cues: [RawEntry]
        }
        struct RawEntry: Decodable {
            let event_id: UInt32
            let delivered: Bool
            let latency_ms: UInt64?
        }
        let raw = try JSONDecoder().decode(RawLog.self, from: data)
        return Dictionary(
            raw.cues.map { ($0.event_id, LatencyEntry(delivered: $0.delivered,
                                                      latencyMs: $0.latency_ms)) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Export

    /// What went in and what came out — the CLI's summary and the
    /// unmatched-segment report (skips are visible, never silent).
    public struct Summary: Equatable, Sendable {
        public let cuesIn: Int
        public let markersIn: Int
        /// Total samples in the trace, fixed or not.
        public let samplesIn: Int
        /// Samples carrying a GPS fix (both lat_e7 and lon_e7 — #110).
        public let samplesWithFix: Int
        public let cueFeatures: Int
        public let markerFeatures: Int
        /// True when the file carries the `kind: "track"` LineString
        /// (requires ≥ 2 fixed samples).
        public let trackEmitted: Bool
        /// Cue features positioned at a GPS fix (`approx` omitted).
        public let exactCues: Int
        /// Marker features positioned at their own GPS fix.
        public let exactMarkers: Int
        /// Cue features carrying an FR-008 outcome.
        public let gradedCues: Int
        /// Cue features that found a sidecar entry (delivered/latency join).
        public let latencyJoins: Int
        /// Cues dropped because the trace holds no route-event observation
        /// for their event id — a trace-integrity problem (truncated or
        /// malformed producer output), not an extract mismatch.
        public let skippedNoEvidence: Int
        /// Cues/markers dropped because their segment id has no match in
        /// the extract (wrong region, or OSM edits changed the ids).
        public let skippedNoSegment: Int
    }

    /// Encode one ride's cue events and markers over the imported
    /// segments. An event whose segment cannot be resolved is skipped and
    /// counted per cause in the summary — the caller decides whether
    /// skips are fatal (`--strict`).
    public static func encode(trace: TraceEvents,
                              latencyByEventID: [UInt32: LatencyEntry] = [:],
                              segments: [RoadSegment]) throws -> (geojson: Data, summary: Summary) {
        // uniquingKeysWith: the importer guarantees unique ids, but a
        // public throws API must not trap on caller-supplied duplicates.
        let segmentsByID = Dictionary(segments.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        // Defensive stable sort by t_ms (index tiebreak): valid traces are
        // already strictly increasing, but the track contract is "ordered
        // by t_ms" and determinism must survive an out-of-spec producer.
        let orderedFixes = trace.gpsFixes.enumerated()
            .sorted { ($0.element.tMs, $0.offset) < ($1.element.tMs, $1.offset) }
            .map { $0.element }
        var features: [Feature] = []
        var skippedNoEvidence = 0
        var skippedNoSegment = 0
        var graded = 0
        var latencyJoins = 0
        var exactCues = 0
        var exactMarkers = 0
        // Track first (the base layer under the event points): one
        // LineString over every fixed sample, or nothing — a single fix
        // is not a path.
        let trackEmitted = orderedFixes.count >= 2
        if trackEmitted {
            features.append(Feature(
                geometry: .lineString(orderedFixes.map {
                    [Double($0.lonE7) / 1e7, Double($0.latE7) / 1e7]
                }),
                properties: .track()))
        }
        for cue in trace.cues {
            guard let evidence = cue.evidence else {
                skippedNoEvidence += 1
                continue
            }
            // The segment join stays mandatory even when a GPS fix could
            // position the cue alone: segment_id is contract-required on
            // every event, and an unmatched extract signals a problem the
            // summary/--strict must keep surfacing.
            guard let segment = segmentsByID[evidence.segmentID] else {
                skippedNoSegment += 1
                continue
            }
            let latency = latencyByEventID[cue.eventID]
            if cue.outcome != nil { graded += 1 }
            if latency != nil { latencyJoins += 1 }
            let position: (coordinates: [Double], approx: Bool?)
            let headingDeg: Double?
            if let fix = nearestFix(to: cue.tMs, in: orderedFixes) {
                position = ([Double(fix.lonE7) / 1e7, Double(fix.latE7) / 1e7],
                            nil)
                // Direction of travel rides with the fix (#144): a
                // midpoint-positioned cue has no course to report, and a
                // courseless fix stays honest — key omitted, never 0. A
                // bearing lives in 0–3599 tenths; anything larger is a
                // malformed producer value and is omitted the same way.
                headingDeg = fix.headingDegX10.flatMap {
                    $0 < 3600 ? Double($0) / 10 : nil
                }
                exactCues += 1
            } else {
                let point = midpoint(of: segment)
                position = ([point.lon, point.lat], true)
                headingDeg = nil
            }
            features.append(Feature(
                geometry: .point(position.coordinates),
                properties: .event(
                    kind: "cue",
                    event_id: cue.eventID,
                    segment_id: evidence.segmentID,
                    ride_clock: rideClock(cue.tMs),
                    lead_time_s: cue.leadTimeS,
                    severity: evidence.severity,
                    confidence: evidence.confidence,
                    reasons_bitmask: evidence.reasonsBitmask,
                    delivered: latency?.delivered,
                    latency_ms: latency?.latencyMs,
                    outcome: cue.outcome,
                    heading_deg: headingDeg,
                    approx: position.approx)))
        }
        for marker in trace.markers {
            guard let segment = segmentsByID[marker.segmentID] else {
                skippedNoSegment += 1
                continue
            }
            let position: (coordinates: [Double], approx: Bool?)
            if let lat = marker.latE7, let lon = marker.lonE7 {
                position = ([Double(lon) / 1e7, Double(lat) / 1e7], nil)
                exactMarkers += 1
            } else {
                let point = midpoint(of: segment)
                position = ([point.lon, point.lat], true)
            }
            features.append(Feature(
                geometry: .point(position.coordinates),
                properties: .event(
                    kind: "marker",
                    segment_id: marker.segmentID,
                    ride_clock: rideClock(marker.tMs),
                    approx: position.approx)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FeatureCollection(features: features))
        let cueFeatures = features.filter { $0.properties.kind == "cue" }.count
        let markerFeatures = features.filter { $0.properties.kind == "marker" }.count
        return (data, Summary(
            cuesIn: trace.cues.count,
            markersIn: trace.markers.count,
            samplesIn: trace.sampleCount,
            samplesWithFix: trace.gpsFixes.count,
            cueFeatures: cueFeatures,
            markerFeatures: markerFeatures,
            trackEmitted: trackEmitted,
            exactCues: exactCues,
            exactMarkers: exactMarkers,
            gradedCues: graded,
            latencyJoins: latencyJoins,
            skippedNoEvidence: skippedNoEvidence,
            skippedNoSegment: skippedNoSegment))
    }

    // MARK: - Helpers

    /// How far a cue's t_ms may sit from the nearest fixed sample and
    /// still count as an exact position (webmap.dev#236). Samples arrive
    /// at ~1 Hz, so 2 s spans a one-sample GPS dropout on either side;
    /// beyond that the fix no longer describes where the cue fired and
    /// the midpoint fallback is more honest.
    static let cueFixToleranceMs: UInt32 = 2_000

    /// The fix nearest tMs within `cueFixToleranceMs`, or nil. `fixes`
    /// must be ordered by t_ms; on an exact distance tie the earlier fix
    /// wins (first strict improvement only — deterministic).
    static func nearestFix(to tMs: UInt32,
                           in fixes: [TraceEvents.GPSFix]) -> TraceEvents.GPSFix? {
        var best: (fix: TraceEvents.GPSFix, distance: UInt32)?
        for fix in fixes {
            let distance = fix.tMs > tMs ? fix.tMs - tMs : tMs - fix.tMs
            if best == nil || distance < best!.distance {
                best = (fix, distance)
            } else if fix.tMs > tMs {
                break  // sorted: remaining fixes are only farther away
            }
        }
        guard let best, best.distance <= cueFixToleranceMs else { return nil }
        return best.fix
    }

    /// Ride clock as "m:ss" from the trace-relative timestamp — the
    /// consumer displays it verbatim (minutes run past 59 on long rides).
    static func rideClock(_ tMs: UInt32) -> String {
        String(format: "%d:%02d", tMs / 60_000, (tMs / 1_000) % 60)
    }

    /// The point at half the segment's polyline length, interpolated on
    /// the bracketing edge — "somewhere on this segment", biased to its
    /// visual center. Deterministic for identical segments (same float
    /// pipeline as the importer's length math).
    static func midpoint(of segment: RoadSegment) -> (lon: Double, lat: Double) {
        let coords = zip(segment.latE7, segment.lonE7).map {
            OverpassCoordinate(lat: Double($0.0) / 1e7, lon: Double($0.1) / 1e7)
        }
        guard let first = coords.first else { return (0, 0) }  // importer forbids
        guard coords.count >= 2 else { return (first.lon, first.lat) }
        let edges = (1..<coords.count).map {
            SegmentImporter.edgeLengthM(coords[$0 - 1], coords[$0])
        }
        let total = edges.reduce(0, +)
        guard total > 0 else { return (first.lon, first.lat) }
        var remaining = total / 2
        for (index, edge) in edges.enumerated() {
            if remaining <= edge {
                let fraction = edge > 0 ? remaining / edge : 0
                let a = coords[index]
                let b = coords[index + 1]
                return (a.lon + (b.lon - a.lon) * fraction,
                        a.lat + (b.lat - a.lat) * fraction)
            }
            remaining -= edge
        }
        // Float residue walked past the last edge: clamp to the end.
        let last = coords[coords.count - 1]
        return (last.lon, last.lat)
    }

    // MARK: - GeoJSON RFC 7946 shapes, limited to the overlay contract.

    private struct FeatureCollection: Encodable {
        let type = "FeatureCollection"
        let features: [Feature]
    }

    private struct Feature: Encodable {
        let type = "Feature"
        let geometry: Geometry
        let properties: Properties
    }

    private enum Geometry: Encodable {
        /// [lon, lat] order per RFC 7946 (both cases).
        case point([Double])
        case lineString([[Double]])

        enum CodingKeys: String, CodingKey { case type, coordinates }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .point(let coordinates):
                try container.encode("Point", forKey: .type)
                try container.encode(coordinates, forKey: .coordinates)
            case .lineString(let coordinates):
                try container.encode("LineString", forKey: .type)
                try container.encode(coordinates, forKey: .coordinates)
            }
        }
    }

    private struct Properties: Encodable {
        let kind: String
        let event_id: UInt32?
        let segment_id: UInt32?
        let ride_clock: String?
        let lead_time_s: Int16?
        let severity: UInt8?
        let confidence: UInt8?
        let reasons_bitmask: UInt16?
        let delivered: Bool?
        let latency_ms: UInt64?
        let outcome: String?
        /// Rider's direction of travel at cue time, degrees clockwise
        /// from north; present only on cue features positioned at a GPS
        /// fix whose sample carried a course. Consumers key on presence.
        let heading_deg: Double?
        /// true = segment midpoint, not a fix; OMITTED when the position
        /// IS a GPS fix (never false) — and on the track feature, whose
        /// coordinates are all fixes. Consumers key on presence.
        let approx: Bool?

        // The designated init stays private: the two factories below are
        // the only doors, so the compiler keeps enforcing that every
        // cue/marker feature carries segment_id and ride_clock (they are
        // optional STORAGE only because the track feature omits them).
        private init(kind: String,
                     event_id: UInt32?,
                     segment_id: UInt32?,
                     ride_clock: String?,
                     lead_time_s: Int16?,
                     severity: UInt8?,
                     confidence: UInt8?,
                     reasons_bitmask: UInt16?,
                     delivered: Bool?,
                     latency_ms: UInt64?,
                     outcome: String?,
                     heading_deg: Double?,
                     approx: Bool?) {
            self.kind = kind
            self.event_id = event_id
            self.segment_id = segment_id
            self.ride_clock = ride_clock
            self.lead_time_s = lead_time_s
            self.severity = severity
            self.confidence = confidence
            self.reasons_bitmask = reasons_bitmask
            self.delivered = delivered
            self.latency_ms = latency_ms
            self.outcome = outcome
            self.heading_deg = heading_deg
            self.approx = approx
        }

        /// The track feature carries only `kind` — no per-event keys.
        static func track() -> Properties {
            Properties(kind: "track", event_id: nil, segment_id: nil,
                       ride_clock: nil, lead_time_s: nil, severity: nil,
                       confidence: nil, reasons_bitmask: nil, delivered: nil,
                       latency_ms: nil, outcome: nil, heading_deg: nil,
                       approx: nil)
        }

        /// Cue/marker features: segment_id and ride_clock are
        /// contract-required (webmap.dev#231), so they are non-optional
        /// HERE even though the stored properties allow the track form.
        static func event(kind: String,
                          event_id: UInt32? = nil,
                          segment_id: UInt32,
                          ride_clock: String,
                          lead_time_s: Int16? = nil,
                          severity: UInt8? = nil,
                          confidence: UInt8? = nil,
                          reasons_bitmask: UInt16? = nil,
                          delivered: Bool? = nil,
                          latency_ms: UInt64? = nil,
                          outcome: String? = nil,
                          heading_deg: Double? = nil,
                          approx: Bool?) -> Properties {
            Properties(kind: kind, event_id: event_id,
                       segment_id: segment_id, ride_clock: ride_clock,
                       lead_time_s: lead_time_s, severity: severity,
                       confidence: confidence,
                       reasons_bitmask: reasons_bitmask,
                       delivered: delivered, latency_ms: latency_ms,
                       outcome: outcome, heading_deg: heading_deg,
                       approx: approx)
        }

        enum CodingKeys: String, CodingKey {
            case kind, event_id, segment_id, ride_clock, lead_time_s
            case severity, confidence, reasons_bitmask
            case delivered, latency_ms, outcome, heading_deg, approx
        }

        // encodeIfPresent so absent optionals carry no keys at all — the
        // consumer contract keys on presence, and a null would read as a
        // value (webmap.dev#231).
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(event_id, forKey: .event_id)
            try container.encodeIfPresent(segment_id, forKey: .segment_id)
            try container.encodeIfPresent(ride_clock, forKey: .ride_clock)
            try container.encodeIfPresent(lead_time_s, forKey: .lead_time_s)
            try container.encodeIfPresent(severity, forKey: .severity)
            try container.encodeIfPresent(confidence, forKey: .confidence)
            try container.encodeIfPresent(reasons_bitmask, forKey: .reasons_bitmask)
            try container.encodeIfPresent(delivered, forKey: .delivered)
            try container.encodeIfPresent(latency_ms, forKey: .latency_ms)
            try container.encodeIfPresent(outcome, forKey: .outcome)
            try container.encodeIfPresent(heading_deg, forKey: .heading_deg)
            try container.encodeIfPresent(approx, forKey: .approx)
        }
    }
}
