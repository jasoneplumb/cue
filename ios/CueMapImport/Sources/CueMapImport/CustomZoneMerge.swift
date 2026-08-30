// Intent: Merge webmap.dev's custom-zones GeoJSON export into a replay
//         trace's personal_memory[] (RFC 0002 D6), for tuning "what if this
//         segment had been rider-flagged unsafe" without needing a live
//         ride — the desk-tool counterpart to the app's "Import custom
//         zones…" action (RideSessionController.importCustomZones), which
//         shares the same snapping logic (CustomZoneImport.matchSegments).
// Pattern: Snaps zones to the region's segments, then replays the trace's
//          own samples/route_events to resolve, per sample, whether a
//          matched segment was observed (CustomZoneImport.
//          personalMemoryChangePoints — the offline mirror of
//          RideTraceRecorder's live carry-forward compression). The output
//          trace's personal_memory[] is REPLACED, not merged additively:
//          this is a what-if tool, not an append (unlike CueReviewMerge,
//          which preserves and appends). schema_version is always written
//          as 2. The trace re-encodes through JSONSerialization with
//          sortedKeys so every other field round-trips untouched, same
//          contract as CueReviewMerge.
import Foundation

public enum CueCustomZoneMergeError: Error, Equatable, CustomStringConvertible {
    case malformedTrace(String)
    case malformedRegion(String)
    case malformedCustomZones(String)
    /// This tool only reads the trace's samples/route_events, so any
    /// schema version the trace itself declares is fine — it never
    /// interprets an existing personal_memory[] — but a completely
    /// unparseable version field is still a shape error.
    case missingSchemaVersion

    public var description: String {
        switch self {
        case .malformedTrace(let reason): return "malformed trace: \(reason)"
        case .malformedRegion(let reason): return "malformed region extract: \(reason)"
        case .malformedCustomZones(let reason): return "malformed custom-zones GeoJSON: \(reason)"
        case .missingSchemaVersion: return "malformed trace: missing schema_version"
        }
    }
}

public enum CueCustomZoneMerge {
    public struct Summary: Equatable, Sendable {
        public let zonesMatched: Int
        public let zonesUnmatched: Int
        public let segmentsMatched: Int
        public let changePoints: Int
    }

    /// Merge `customZones` (webmap.dev's export) into `trace`'s
    /// personal_memory[], snapping to segments derived from `region` (the
    /// same Overpass extract cue-zone-export consumes). All-or-nothing:
    /// throws before producing anything on the first malformed input.
    public static func merge(trace traceData: Data, customZones customZonesData: Data,
                             region regionData: Data) throws -> (trace: Data, summary: Summary) {
        let segments: [RoadSegment]
        do {
            let extract = try OverpassExtract(data: regionData)
            segments = try SegmentImporter.deriveSegments(from: extract)
        } catch {
            throw CueCustomZoneMergeError.malformedRegion(String(describing: error))
        }

        let features: [CustomZoneFeature]
        do {
            features = try CustomZoneImport.parseFeatures(from: customZonesData)
        } catch {
            throw CueCustomZoneMergeError.malformedCustomZones(String(describing: error))
        }
        let matchResult = CustomZoneImport.matchSegments(for: features, segments: segments)
        // Directions are carried but not yet consulted here — gating a
        // desk what-if needs the trace's own per-sample heading, which is
        // cue#30 Phase 4. Until then a directional zone merges exactly as a
        // bidirectional one does, i.e. as it did before cue#30.
        let matchedSegmentIDs = Set(matchResult.directionsBySegment.keys)

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: traceData)
        } catch {
            throw CueCustomZoneMergeError.malformedTrace(String(describing: error))
        }
        guard let root = jsonObject as? [String: Any] else {
            throw CueCustomZoneMergeError.malformedTrace("not a JSON object")
        }
        guard root["schema_version"] != nil else {
            throw CueCustomZoneMergeError.missingSchemaVersion
        }
        guard let samplesArray = root["samples"] as? [[String: Any]] else {
            throw CueCustomZoneMergeError.malformedTrace("missing or non-array samples")
        }
        let sampleTMs: [UInt32] = try samplesArray.map { sample in
            guard let number = sample["t_ms"] as? NSNumber,
                  let value = UInt32(exactly: number) else {
                throw CueCustomZoneMergeError.malformedTrace("sample missing/invalid t_ms")
            }
            return value
        }
        if let first = sampleTMs.first {
            var prev = first
            for tMs in sampleTMs.dropFirst() {
                // replay_main.c's decode_samples requires STRICTLY increasing
                // t_ms (the kernel itself tolerates non-decreasing, but the
                // harness does not) — matching that here means a merge that
                // "succeeds" is guaranteed to actually replay.
                guard tMs > prev else {
                    throw CueCustomZoneMergeError.malformedTrace(
                        "samples not strictly increasing by t_ms (found \(tMs) after \(prev))")
                }
                prev = tMs
            }
        }
        guard let eventsArray = root["route_events"] as? [[String: Any]] else {
            throw CueCustomZoneMergeError.malformedTrace("missing or non-array route_events")
        }
        var observedSegmentIDs: [UInt32: [UInt32]] = [:]
        for event in eventsArray {
            guard let tNumber = event["t_ms"] as? NSNumber, let tMs = UInt32(exactly: tNumber),
                  let segNumber = event["segment_id"] as? NSNumber,
                  let segmentID = UInt32(exactly: segNumber) else {
                throw CueCustomZoneMergeError.malformedTrace(
                    "route_events entry missing/invalid t_ms or segment_id")
            }
            observedSegmentIDs[tMs, default: []].append(segmentID)
        }

        let changePoints = CustomZoneImport.personalMemoryChangePoints(
            matchedSegmentIDs: matchedSegmentIDs, sampleTMs: sampleTMs,
            observedSegmentIDs: observedSegmentIDs)

        var output = root
        output["schema_version"] = 2
        output["personal_memory"] = changePoints.map { point in
            [
                "t_ms": point.tMs,
                "segment_id": point.segmentID,
                "state": point.state,
                "notice_bonus_s": point.noticeBonusS,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        return (data, Summary(
            zonesMatched: matchResult.matches.count,
            zonesUnmatched: matchResult.unmatchedZoneIDs.count,
            segmentsMatched: matchedSegmentIDs.count,
            changePoints: changePoints.count))
    }
}
