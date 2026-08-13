// Intent: Phone-side dispatch policy and the D4 latency instrument
//         (asmp0002 / meas0002): every HEAD_UP goes out over the best
//         available path — live send when the watch is reachable, queued
//         fallback otherwise or on live failure — and every cue's
//         dispatch/delivery timestamps are logged so §13 tuning sees
//         delivery lag, not just kernel lead time.
// Context: If measured p95 delivery exceeds 2 s, the remedy is a MANUAL,
//          between-rides min_notice_s bias through the normal §13 loop —
//          never a runtime auto-adjustment (the kernel's config must match
//          what the trace records, or replay diverges; NFR-003/D4).
// Pattern: Transport is a protocol so the logic tests on macOS; the
//          WCSession adapter lives in the app target. Latency records
//          export as a SIDECAR JSON — trace schema v1 has no delivery
//          fields; folding them in is a schema-v2 decision, not smuggled
//          in here.
import CueKernel
import Foundation

/// The transport the app layer implements over WCSession.
public protocol CueTransport {
    /// Interactive path available (WCSession.isReachable analog).
    var isReachable: Bool { get }
    /// Near-real-time send (sendMessage). `onDeliveryAck` fires when the
    /// watch replied — delivery is then certain — carrying the decoded
    /// reply (watch wall clock at receipt, gate verdict, workout flag;
    /// every field nil when the reply lacked it — delivered either way).
    /// `onFailure` fires on send error — the dispatcher then falls back
    /// to the queued path.
    func sendLive(_ message: [String: Any],
                  onDeliveryAck: @escaping (CueDeliveryAck) -> Void,
                  onFailure: @escaping () -> Void)
    /// Queued eventually-delivered send (transferUserInfo). No ack.
    func sendQueued(_ message: [String: Any])
}

/// One cue's lifecycle in the latency log.
public struct CueLinkRecord: Equatable, Sendable {
    public enum Path: String, Sendable {
        case live
        case liveFellBackToQueued = "live_fallback_queued"
        case queued
    }

    public let eventID: UInt32
    public let dispatchTsMs: UInt64
    public let expiresAfterS: UInt16
    public internal(set) var path: Path
    /// True once the watch's live-path reply arrived: delivery is certain
    /// even when the reply carried no readable timestamp. Queued sends
    /// have no ack channel and stay false — at ride end that means
    /// "undelivered as far as the phone knows", which §13 counts against
    /// coverage rather than pretending delivery.
    public internal(set) var delivered: Bool
    /// Watch wall clock at receipt, from the live-path ack; nil while
    /// unacked or when the ack carried no readable timestamp.
    public internal(set) var deliveryTsMs: UInt64?
    /// What the watch's expiry gate did with the cue ("play" / "expired" /
    /// "duplicate"), from the live-path ack; nil while unacked or from
    /// watch builds that predate RFC 0004. "play" means the haptic was
    /// REQUESTED — perception is the rider's side of the contract.
    public internal(set) var watchVerdict: String?
    /// Whether the watch held a live workout session at receipt — the
    /// haptic-eligibility proxy (RFC 0004). nil when unacked/unreported.
    /// delivered=true with workoutActive=false is the "acked but the
    /// haptic call was a silent no-op" signature ride 2026-07-14 couldn't
    /// distinguish.
    public internal(set) var workoutActive: Bool?

    /// nil when unmeasured — including when the watch clock reads BEHIND
    /// the phone's dispatch instant: that is cross-clock skew corrupting
    /// the measurement, not a 0 ms delivery, and a phantom 0 would bias
    /// the asmp0002 p95 downward.
    public var latencyMs: UInt64? {
        deliveryTsMs.flatMap { $0 >= dispatchTsMs ? $0 - dispatchTsMs : nil }
    }
}

/// One ride's dispatcher. Feed it every kernel decision; it sends the
/// HEAD_UPs and builds the latency log.
///
/// @unchecked Sendable: `dispatch()` runs on the ride-engine thread while
/// the ack/failure closures arrive on the transport's reply queue —
/// `recordsLock` serializes every access to `records`; transport calls
/// are never made while the lock is held.
public final class CueDispatcher: @unchecked Sendable {
    private let transport: CueTransport
    /// Unix epoch ms of the ride's t_ms = 0 — dispatch_ts anchors to the
    /// kernel decision instant (ride start + sample t_ms), per D4.
    private let rideStartEpochMs: UInt64
    private let recordsLock = NSLock()
    private var _records: [CueLinkRecord] = []

    var records: [CueLinkRecord] {
        recordsLock.lock()
        defer { recordsLock.unlock() }
        return _records
    }

    public init(transport: CueTransport, rideStartEpochMs: UInt64) {
        self.transport = transport
        self.rideStartEpochMs = rideStartEpochMs
    }

    /// Dispatch one kernel decision. Non-HEAD_UP decisions are ignored —
    /// the watch link carries cues, nothing else.
    public func dispatch(_ decision: CueDecision, sampleTMs: UInt32) {
        guard decision.isHeadUp else { return }
        // HEAD_UP always carries a computed lead time; clamp defensively
        // so a pathological negative never becomes a huge UInt16.
        let expiresAfterS = UInt16(max(0, Int(decision.lead_time_s)))
        let payload = CuePayload(
            eventID: decision.event_id,
            dispatchTsMs: rideStartEpochMs + UInt64(sampleTMs),
            expiresAfterS: expiresAfterS)
        if transport.isReachable {
            let index = append(makeRecord(payload, path: .live))
            transport.sendLive(
                payload.encoded(),
                onDeliveryAck: { [weak self] ack in
                    self?.mutateRecord(at: index) {
                        $0.delivered = true
                        $0.deliveryTsMs = ack.deliveryTsMs
                        $0.watchVerdict = ack.verdict
                        $0.workoutActive = ack.workoutActive
                    }
                },
                onFailure: { [weak self, transport] in
                    // Reachability flapped mid-send: queue it — late
                    // delivery is the watch-side expiry gate's problem,
                    // and an unlogged lost cue would be worse. The
                    // transport is captured strongly so the fallback send
                    // happens even if the dispatcher (and its log) is
                    // already gone at ride end.
                    self?.mutateRecord(at: index) { $0.path = .liveFellBackToQueued }
                    transport.sendQueued(payload.encoded())
                })
        } else {
            _ = append(makeRecord(payload, path: .queued))
            transport.sendQueued(payload.encoded())
        }
    }

    private func append(_ record: CueLinkRecord) -> Int {
        recordsLock.lock()
        defer { recordsLock.unlock() }
        _records.append(record)
        return _records.count - 1
    }

    private func mutateRecord(at index: Int, _ mutate: (inout CueLinkRecord) -> Void) {
        recordsLock.lock()
        defer { recordsLock.unlock() }
        mutate(&_records[index])
    }

    private func makeRecord(_ payload: CuePayload,
                            path: CueLinkRecord.Path) -> CueLinkRecord {
        CueLinkRecord(eventID: payload.eventID,
                      dispatchTsMs: payload.dispatchTsMs,
                      expiresAfterS: payload.expiresAfterS,
                      path: path, delivered: false, deliveryTsMs: nil,
                      watchVerdict: nil, workoutActive: nil)
    }

    /// p95 delivery latency over cues with MEASURED latency, ms — the
    /// asmp0002 metric (target: ≤ 2000 during real rides). nil until at
    /// least one timestamped ack.
    public var p95LatencyMs: UInt64? {
        Self.p95(over: records)
    }

    private static func p95(over records: [CueLinkRecord]) -> UInt64? {
        let latencies = records.compactMap(\.latencyMs).sorted()
        guard !latencies.isEmpty else { return nil }
        let rank = Int((Double(latencies.count) * 0.95).rounded(.up)) - 1
        return latencies[max(0, min(latencies.count - 1, rank))]
    }

    /// Sidecar latency log (see header). Deterministic: sortedKeys, and
    /// records are in dispatch order.
    public func exportLatencyLog(rideID: String) throws -> Data {
        struct Entry: Encodable {
            let event_id: UInt32
            let dispatch_ts_ms: UInt64
            let expires_after_s: UInt16
            let path: String
            let delivered: Bool
            let delivery_ts_ms: UInt64?
            let latency_ms: UInt64?
            let watch_verdict: String?
            let workout_active: Bool?
        }
        struct Log: Encodable {
            let ride_id: String
            let cues: [Entry]
            let p95_latency_ms: UInt64?
            let undelivered_count: Int
        }
        // ONE snapshot feeds both the entries and the p95 — a late ack
        // landing mid-export must not make the summary disagree with the
        // rows it summarizes.
        let snapshot = records
        let log = Log(
            ride_id: rideID,
            cues: snapshot.map {
                Entry(event_id: $0.eventID, dispatch_ts_ms: $0.dispatchTsMs,
                      expires_after_s: $0.expiresAfterS, path: $0.path.rawValue,
                      delivered: $0.delivered,
                      delivery_ts_ms: $0.deliveryTsMs, latency_ms: $0.latencyMs,
                      watch_verdict: $0.watchVerdict,
                      workout_active: $0.workoutActive)
            },
            p95_latency_ms: Self.p95(over: snapshot),
            // Undelivered means NOT ACKED — a reply without a readable
            // timestamp is still a delivery, just latency-unmeasurable;
            // counting it as coverage loss would corrupt the §13 metric.
            undelivered_count: snapshot.filter { !$0.delivered }.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(log)
    }
}
