// Intent: D6's in-app GPX playback harness (RFC 0003 follow-up 9): parse a
//         GPX 1.1 track into RideFix values and drive a fresh RideEngine
//         over imported map data, so the E2E loop — cue timing inside the
//         notice window, exported trace divergence-free through replay_cli
//         — is exercised in the simulator, never first in traffic.
// Context: Platform-neutral like the rest of CueRideEngine: Foundation's
//          XMLParser only, no CoreLocation and no GPX dependency, so
//          `swift test` runs the whole loop on macOS. Speed/heading
//          derivation uses the same equirectangular constants as
//          SegmentImporter.edgeLengthM (111320*cos(midLat) / 110540) so
//          simulated speeds agree with imported segment lengths.
// Pattern: Deterministic for identical inputs (NFR-003): fix derivation is
//          pure arithmetic over the parsed points, the engine is the same
//          one live rides use, and trace bytes are stable because the
//          recorder encodes with sortedKeys. Malformed input fails with a
//          typed error — a silently empty scenario would pass every
//          vacuous assertion.
import CueKernel
import CueMapImport
import Foundation

/// Why a GPX document (or its track timing) was rejected.
public enum GPXPlaybackError: Error, Equatable {
    /// Not well-formed XML at all.
    case malformedXML(line: Int, column: Int)
    /// A `trkpt` without parseable, finite `lat`/`lon` attributes.
    case invalidTrackPoint(line: Int)
    /// A `trkpt/time` that is not ISO 8601.
    case invalidTime(value: String)
    /// Well-formed XML but no `trk/trkseg/trkpt` anywhere — an empty
    /// scenario is a harness bug, not a passing ride.
    case noTrackPoints
    /// The track's time span exceeds what uint32 milliseconds can carry
    /// (~49.7 days) — a typed rejection, never a runtime trap: this is a
    /// public throws API and every failure mode must be recoverable.
    case timeSpanTooLarge(pointIndex: Int)
    /// Timestamped points must be strictly increasing: the ride engine
    /// (and the replay schema) require strictly increasing t_ms, so a
    /// reordered track is rejected here instead of silently dropping fixes.
    case nonChronologicalTime(pointIndex: Int)
}

/// One parsed `trkpt`: ordered as they appear in the document.
public struct GPXTrackPoint: Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    /// From the point's `time` element, when present.
    public let time: Date?

    public init(lat: Double, lon: Double, time: Date?) {
        self.lat = lat
        self.lon = lon
        self.time = time
    }
}

public enum GPXPlayback {
    /// Ordered track points from a GPX 1.1 document (`trk/trkseg/trkpt`
    /// only — route `rtept` and lone waypoints are not ride playback).
    public static func trackPoints(from data: Data) throws -> [GPXTrackPoint] {
        let parser = XMLParser(data: data)
        let delegate = GPXDelegate()
        parser.delegate = delegate
        let completed = parser.parse()
        // The delegate's typed error wins over the generic abort error the
        // parser reports after abortParsing().
        if let error = delegate.typedError { throw error }
        if !completed {
            throw GPXPlaybackError.malformedXML(line: parser.lineNumber,
                                                column: parser.columnNumber)
        }
        guard !delegate.points.isEmpty else { throw GPXPlaybackError.noTrackPoints }
        return delegate.points
    }

    /// Track points → engine-ready fixes. t_ms comes from `time` elements
    /// relative to the first point when EVERY point carries one (mixed
    /// timing has no honest interpolation), else 1000 ms per point — the
    /// engine's 1 Hz cadence. Speed and heading derive from consecutive
    /// points; the first fix reuses the second's leg (a real receiver
    /// reports course/speed from the first movement, not zeros).
    public static func rideFixes(from points: [GPXTrackPoint]) throws -> [RideFix] {
        guard !points.isEmpty else { throw GPXPlaybackError.noTrackPoints }
        let tMs = try timestamps(for: points)

        // Per-leg speed/heading between consecutive points. A zero-length
        // leg has no bearing: heading is nil (CoreLocation's "course
        // invalid when stationary"), never a fabricated north.
        var legs: [(speedMps: Double, headingDeg: Double?)] = []
        for i in 1..<points.count {
            let (dx, dy) = metersOffset(from: points[i - 1], to: points[i])
            let distanceM = (dx * dx + dy * dy).squareRoot()
            let dtS = Double(tMs[i] - tMs[i - 1]) / 1000  // > 0: strictly increasing
            let heading: Double?
            if distanceM > 0 {
                let bearing = atan2(dx, dy) * 180 / .pi
                heading = bearing < 0 ? bearing + 360 : bearing
            } else {
                heading = nil
            }
            legs.append((distanceM / dtS, heading))
        }

        return points.indices.map { i in
            // Fix i ends leg i-1; fix 0 borrows leg 0. A single-point
            // track is a stationary fix: speed 0, course unknown.
            let leg: (speedMps: Double, headingDeg: Double?) =
                legs.isEmpty ? (0, nil) : legs[max(i - 1, 0)]
            return RideFix(tMs: tMs[i], lat: points[i].lat, lon: points[i].lon,
                           speedMps: leg.speedMps, headingDeg: leg.headingDeg)
        }
    }

    /// Parse + convert in one step.
    public static func rideFixes(from data: Data) throws -> [RideFix] {
        try rideFixes(from: trackPoints(from: data))
    }

    private static func timestamps(for points: [GPXTrackPoint]) throws -> [UInt32] {
        guard points.allSatisfy({ $0.time != nil }) else {
            return (0..<points.count).map { UInt32($0) * 1000 }
        }
        let start = points[0].time!
        var result: [UInt32] = []
        for (index, point) in points.enumerated() {
            let offsetS = point.time!.timeIntervalSince(start)
            guard offsetS >= 0 else {
                throw GPXPlaybackError.nonChronologicalTime(pointIndex: index)
            }
            let offsetMs = (offsetS * 1000).rounded()
            guard offsetMs <= Double(UInt32.max) else {
                throw GPXPlaybackError.timeSpanTooLarge(pointIndex: index)
            }
            let ms = UInt32(offsetMs)
            if let last = result.last, ms <= last {
                throw GPXPlaybackError.nonChronologicalTime(pointIndex: index)
            }
            result.append(ms)
        }
        return result
    }

    /// Equirectangular offset in meters — the same constants as
    /// SegmentImporter.edgeLengthM, so a GPX point 6 m east of the last
    /// yields exactly the speed the imported geometry implies.
    private static func metersOffset(from a: GPXTrackPoint,
                                     to b: GPXTrackPoint) -> (dx: Double, dy: Double) {
        let midLatRad = (a.lat + b.lat) / 2 * .pi / 180
        let dx = (b.lon - a.lon) * 111_320.0 * cos(midLatRad)
        let dy = (b.lat - a.lat) * 110_540.0
        return (dx, dy)
    }
}

/// XMLParser delegate collecting `trk/trkseg/trkpt` in document order.
/// Aborts on the first structural violation so the typed error names the
/// offending point instead of yielding a truncated track.
private final class GPXDelegate: NSObject, XMLParserDelegate {
    var points: [GPXTrackPoint] = []
    var typedError: GPXPlaybackError?

    private var elementStack: [String] = []
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingTime: Date?
    private var timeText = ""
    private var capturingTime = false

    // Two formatters because GPX writers split on fractional seconds and
    // ISO8601DateFormatter accepts exactly one shape per configuration.
    // Instance-owned (one delegate per parse), not static: the class is
    // not Sendable and Swift 6 rejects shared non-Sendable globals.
    private let isoPlain = ISO8601DateFormatter()
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var insideTrkpt: Bool { elementStack.contains("trkpt") }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "trkpt",
           elementStack.suffix(2).elementsEqual(["trk", "trkseg"]) {
            // Physical WGS-84 range, not just finiteness: the engine
            // silently drops out-of-range fixes, so accepting lat=91 here
            // would turn a corrupt file into a mysteriously empty ride
            // instead of a typed rejection.
            guard let lat = attributeDict["lat"].flatMap(Double.init), lat.isFinite,
                  let lon = attributeDict["lon"].flatMap(Double.init), lon.isFinite,
                  abs(lat) <= 90, abs(lon) <= 180 else {
                typedError = .invalidTrackPoint(line: parser.lineNumber)
                parser.abortParsing()
                return
            }
            pendingLat = lat
            pendingLon = lon
            pendingTime = nil
        } else if elementName == "time", insideTrkpt {
            capturingTime = true
            timeText = ""
        }
        elementStack.append(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTime { timeText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if !elementStack.isEmpty { elementStack.removeLast() }
        if elementName == "time", capturingTime {
            capturingTime = false
            let raw = timeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = isoPlain.date(from: raw)
                ?? isoFractional.date(from: raw) else {
                typedError = .invalidTime(value: raw)
                parser.abortParsing()
                return
            }
            pendingTime = parsed
        } else if elementName == "trkpt",
                  let lat = pendingLat, let lon = pendingLon {
            points.append(GPXTrackPoint(lat: lat, lon: lon, time: pendingTime))
            pendingLat = nil
            pendingLon = nil
            pendingTime = nil
        }
    }
}

/// What one simulated ride produced — everything the D6 assertions need.
public struct GPXScenarioResult {
    /// One HEAD_UP the kernel emitted during playback.
    public struct HeadUp: Equatable, Sendable {
        public let tMs: UInt32
        public let eventID: UInt32
        public let leadTimeS: Int16
    }

    /// The ride's exported policy trace (no GPS — NFR-005), byte-stable
    /// for identical inputs and ready for replay_cli.
    public let trace: Data
    /// The config the scenario actually ran (caller's, or the spec §8
    /// defaults) — replay-equivalence checks must construct their fresh
    /// kernel from THIS, or a custom-config scenario silently
    /// divergence-checks against the wrong policy.
    public let config: CuePolicyConfig
    public let headUps: [HeadUp]
    /// True when every HEAD_UP's lead time landed inside the config's
    /// [min_notice_s, max_notice_s] window. Vacuously true with no cues —
    /// pair with a cue-count assertion (NFR-001 wants exactly one per
    /// event, not merely well-timed ones).
    public let leadTimesInWindow: Bool
}

/// Drives one simulated GPX ride through a fresh RideEngine — the same
/// pipeline a live ride uses, minus CoreLocation.
public enum GPXScenarioRunner {
    /// `config == nil` runs the spec §8 defaults, matching RideEngine.
    /// Fixed rideID/startedAt defaults keep two runs of the same scenario
    /// byte-identical; override only when a test needs distinct traces.
    public static func run(gpx: Data,
                           segments: [RoadSegment],
                           zones: [SqueezeZone],
                           config: CuePolicyConfig? = nil,
                           rideID: String = "gpx-scenario",
                           startedAt: String = "1970-01-01T00:00:00Z") throws -> GPXScenarioResult {
        let fixes = try GPXPlayback.rideFixes(from: gpx)
        let engine = RideEngine(segments: segments, zones: zones, config: config,
                                rideID: rideID, startedAt: startedAt)
        var headUps: [GPXScenarioResult.HeadUp] = []
        for fix in fixes {
            guard let decision = engine.process(fix), decision.isHeadUp else { continue }
            headUps.append(.init(tMs: fix.tMs, eventID: decision.event_id,
                                 leadTimeS: decision.lead_time_s))
        }
        let resolved = config ?? CuePolicy.defaultConfig()
        let window = Int(resolved.min_notice_s)...Int(resolved.max_notice_s)
        return GPXScenarioResult(
            trace: try engine.recorder.exportPolicyTrace(),
            config: resolved,
            headUps: headUps,
            leadTimesInWindow: headUps.allSatisfy { window.contains(Int($0.leadTimeS)) })
    }
}
