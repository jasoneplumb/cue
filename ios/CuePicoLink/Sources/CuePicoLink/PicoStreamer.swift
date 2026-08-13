// Intent: The phone side of the RFC 0006 step stream — assigns sequence
//         numbers, keeps un-acked steps for reconnect (D4), and compares
//         every decision the Pico reports against the phone's own shadow
//         step (D2). A mismatch is an NFR-003 divergence caught in-ride
//         rather than in post-ride replay.
// Context: The Pico is authoritative for actuation; the phone keeps
//          stepping the same kernel because it is the trace producer
//          anyway, which makes the comparison free.
// Pattern: Transport-free by design — this owns the protocol state and
//          hands back Data to write, so it is fully testable under
//          `swift test` with no CoreBluetooth and no hardware. The BLE
//          glue lives in the app target (same split as CueWatchLink).
//          Not thread-safe: drive it from the ride loop only.
import CueKernel
import Foundation

/// One step's worth of evidence: what the phone decided, what the Pico
/// reported, and whether they agreed. This is the per-ride artifact the
/// D5 acceptance gate reads.
public struct PicoStepRecord: Codable, Equatable, Sendable {
    public let seq: UInt16
    public let tMs: UInt32
    /// Phone-shadow decision fields.
    public let shadowType: UInt8
    public let shadowEventID: UInt32
    public let shadowReasonCode: UInt8
    public let shadowLeadTimeS: Int16
    /// Pico-reported decision fields; nil until its notify arrives (or
    /// forever, if the link dropped before it did).
    public var picoType: UInt8?
    public var picoEventID: UInt32?
    public var picoReasonCode: UInt8?
    public var picoLeadTimeS: Int16?
    /// True when the Pico actually drove the actuator.
    public var actuated: Bool?
    /// Microseconds (v2). See `CuePicoWire.DecisionReport`.
    public var actuationDelayUs: UInt16?
    /// Set when the two kernels disagreed on any decision field.
    public var diverged: Bool?
    /// True for a step replayed after a reconnect, which advances the
    /// kernel but must not actuate (NFR-001). Set when the step is
    /// actually replayed, so the sidecar can tell an intentional
    /// non-actuation from a cue that failed to reach the rider.
    public var catchup: Bool

    enum CodingKeys: String, CodingKey {
        case seq
        case tMs = "t_ms"
        case shadowType = "shadow_type"
        case shadowEventID = "shadow_event_id"
        case shadowReasonCode = "shadow_reason_code"
        case shadowLeadTimeS = "shadow_lead_time_s"
        case picoType = "pico_type"
        case picoEventID = "pico_event_id"
        case picoReasonCode = "pico_reason_code"
        case picoLeadTimeS = "pico_lead_time_s"
        case actuated
        case actuationDelayUs = "actuation_delay_us"
        case diverged
        case catchup
    }
}

/// One VSYS reading, stamped on the ride clock.
///
/// `tMs` is the most recent step's `t_ms` rather than a wall clock: it is
/// the only timebase the sidecar already uses, so a battery sample can be
/// read against the step records without correlating two clocks. Samples
/// taken before the first step carry 0.
public struct PicoBatterySample: Codable, Equatable, Sendable {
    public let tMs: UInt32
    /// nil when the device could not measure VSYS (its ADC read timed
    /// out). Optional rather than 0 because the supply beside it is still
    /// valid — the firmware reads VBUS before the ADC — and dropping the
    /// whole sample would discard supply evidence the D5 gate depends on.
    public let batteryMv: UInt16?
    /// The supply these millivolts were measured against. Carried per
    /// sample, not once per ride: a cable pulled mid-ride changes what
    /// the number means, and a single header value would hide that.
    public let supply: CuePicoWire.Supply

    public init(tMs: UInt32, batteryMv: UInt16?,
                supply: CuePicoWire.Supply) {
        self.tMs = tMs
        self.batteryMv = batteryMv
        self.supply = supply
    }

    enum CodingKeys: String, CodingKey {
        case tMs = "t_ms"
        case batteryMv = "battery_mv"
        case supply
    }
}

public final class PicoStreamer {
    /// What the caller must do after a reconnect.
    public enum ResumePlan: Equatable, Sendable {
        /// Re-send exactly these steps, already flagged non-actuating.
        case replay([Data])
        /// The Pico lost the ride (reboot), or the backlog outran the
        /// ring: start over with SESSION_START and re-stream from seq 0,
        /// rebuilt from the trace recorder (D4).
        case fullRestream
    }

    public let rideIDHash: UInt32
    private let config: CuePolicyConfig

    /// Un-acked steps, oldest first. Bounded: a disconnect that outlives
    /// it degrades to a full re-stream, never to a silent gap (D4).
    private var pending: [(seq: UInt16, payload: Data)] = []
    /// Set when the ring dropped a step, so resume cannot be partial.
    private var ringOverflowed = false

    private var nextSeq: UInt16 = 1
    /// Highest seq the transport has confirmed. Advisory on the wire —
    /// the Pico's own last-processed seq wins — but it is what we tell it
    /// we believe, which helps diagnose a mismatch.
    private var lastAckedSeq: UInt16 = 0
    private var records: [UInt16: PicoStepRecord] = [:]
    private var order: [UInt16] = []

    /// Reports for a seq this streamer never sent. Kept as a counter
    /// because there is no record to derive it from — and safe as one
    /// because it only ever increases; nothing rolls it back.
    public private(set) var orphanReportCount = 0

    /// VSYS readings taken across the ride, oldest first (D5).
    public private(set) var batterySamples: [PicoBatterySample] = []

    /// DERIVED, not accumulated. These two were running counters, and two
    /// separate bugs came from a state transition forgetting to adjust
    /// them (a reconnect double-counting a divergence, and a replayed
    /// step's rollback missing a field). Both are the metrics the D5
    /// acceptance gate reads, so a stale one condemns a working device or
    /// clears a broken one. Deriving them from the records makes
    /// "counter disagrees with the records" unrepresentable rather than
    /// merely tested-for. O(n) per read with n ≈ 10k on a 3-hour ride,
    /// and nothing reads them on the 1 Hz path.
    public var divergenceCount: Int {
        orphanReportCount + records.values.filter { $0.diverged == true }.count
    }

    public var reportedCount: Int {
        orphanReportCount + records.values.filter { $0.picoType != nil }.count
    }

    public init(rideIDHash: UInt32, config: CuePolicyConfig) {
        self.rideIDHash = rideIDHash
        self.config = config
    }

    /// A ride identifier safe to put on an unencrypted link.
    ///
    /// The hash travels in plaintext in SESSION_START/RESUME, so it must
    /// not be derived from anything locational — a start position, a route
    /// fingerprint, or a segment id would let a passive listener correlate
    /// rides to places, which is precisely the NFR-005 exposure the wire
    /// format otherwise avoids by zeroing coordinates. It only has to
    /// distinguish this ride from the previous one on reconnect, so a
    /// random value is both sufficient and the safest choice.
    public static func makeRideIDHash() -> UInt32 {
        UInt32.random(in: UInt32.min...UInt32.max)
    }

    // MARK: - Session

    public func sessionStartPayload() -> Data {
        CuePicoWire.packSessionStart(rideIDHash: rideIDHash, config: config)
    }

    /// The D6 width tripwire. A Pico whose `CuePolicyState` is laid out
    /// differently than the phone's would diverge from the first step, so
    /// there is no safe way to continue — the caller must abort the
    /// session rather than stream into it.
    public func validate(sessionAck ack: CuePicoWire.SessionAck,
                         expectedStateSize: UInt16) -> Bool {
        ack.status == .ok && ack.stateSize == expectedStateSize
    }

    // MARK: - Streaming

    /// Pack the next step and remember it for a possible replay.
    ///
    /// `shadowDecision` is the decision the phone's own kernel produced
    /// for this same input — it must come from the same call that fed the
    /// trace recorder, not a re-derivation, or the comparison would be
    /// checking two different things.
    public func makeStep(sample: RideSample,
                         events: [RouteEvent],
                         memory: PersonalMemory?,
                         shadowDecision: CueDecision) -> Data? {
        guard let payload = CuePicoWire.packStep(seq: nextSeq,
                                                 sample: sample,
                                                 events: events,
                                                 memory: memory) else {
            return nil // over the event cap; caller must truncate upstream
        }
        let seq = nextSeq
        nextSeq &+= 1

        records[seq] = PicoStepRecord(
            seq: seq, tMs: sample.t_ms,
            shadowType: shadowDecision.type,
            shadowEventID: shadowDecision.event_id,
            shadowReasonCode: shadowDecision.reason_code,
            shadowLeadTimeS: shadowDecision.lead_time_s,
            catchup: false)
        order.append(seq)

        pending.append((seq: seq, payload: payload))
        if pending.count > CuePicoWire.ringCapacity {
            pending.removeFirst()
            ringOverflowed = true
        }
        return payload
    }

    /// Called when the transport confirms the write landed. Everything up
    /// to and including `seq` leaves the replay set.
    ///
    /// IMPORTANT — what "landed" has to mean: only call this for a signal
    /// that implies the Pico's kernel has *processed* the step, not merely
    /// received it. Dropping a step from the replay set before the kernel
    /// consumed it would make a disconnect in that window return an empty
    /// replay and leave the two kernels permanently out of step.
    ///
    /// The ATT write response satisfies this **because of how the firmware
    /// is built**: `cue_ble.c` runs `cue_session_handle_step` inside the
    /// ATT write callback, so BTstack only emits the response after the
    /// kernel has stepped. That is a firmware invariant this API depends
    /// on — if STEP ever moves to write-without-response, or the firmware
    /// starts deferring the step off the callback, acknowledgement must
    /// move to the DECISION notify instead.
    ///
    /// The `<=` (and `resumePlan`'s `>`) compare seq numbers as plain
    /// integers, which would misbehave once `nextSeq` wraps at 65535. At
    /// 1 Hz that is ~18 hours of continuous riding, and a PicoStreamer is
    /// built per ride, so the wrap is unreachable in practice — noted so
    /// it does not have to be re-investigated.
    public func acknowledge(seq: UInt16) {
        pending.removeAll { $0.seq <= seq }
        if seq > lastAckedSeq { lastAckedSeq = seq }
    }

    /// True once any step has been sent, i.e. a session exists on the Pico
    /// worth resuming rather than restarting.
    public var hasStarted: Bool { nextSeq > 1 }

    /// SESSION_RESUME for the current ride.
    public func resumePayload() -> Data {
        CuePicoWire.packSessionResume(rideIDHash: rideIDHash,
                                      lastAckedSeq: lastAckedSeq)
    }

    // MARK: - Decisions

    /// Fold in one DECISION notify and compare it against the shadow.
    /// Returns true when the two kernels agreed (or when the report is for
    /// a step this streamer never sent, which is reported as a divergence
    /// rather than ignored).
    @discardableResult
    public func handle(decisionReport data: Data) -> Bool {
        guard let report = CuePicoWire.unpackDecisionReport(data) else {
            return false
        }
        guard var record = records[report.seq] else {
            // A decision for a step we never sent means the two sides
            // disagree about the sequence itself — worse than a field
            // mismatch, so it counts.
            orphanReportCount += 1
            return false
        }
        // BLE notifications are best-effort and unacknowledged, so the
        // same report can arrive twice — most likely as a stale one the
        // OS replays on reconnect. Fold it in once: a second pass would
        // double-count both aggregates, or silently rewrite `diverged`
        // without adjusting the counter. A step that was genuinely
        // replayed has had its Pico fields cleared by resumePlan, so its
        // new report is still accepted.
        if record.picoType != nil {
            return record.diverged == false
        }
        record.picoType = report.type
        record.picoEventID = report.eventID
        record.picoReasonCode = report.reasonCode
        record.picoLeadTimeS = report.leadTimeS
        record.actuated = report.actuated
        record.actuationDelayUs = report.actuationDelayUs

        // The same four fields replay_main.c compares. `actuated` is
        // deliberately excluded: it is a property of the delivery path,
        // not of the kernel decision, and a catch-up step legitimately
        // decides HEAD_UP without actuating.
        let agreed = report.type == record.shadowType
            && report.eventID == record.shadowEventID
            && report.reasonCode == record.shadowReasonCode
            && report.leadTimeS == record.shadowLeadTimeS
        record.diverged = !agreed
        records[report.seq] = record
        return agreed
    }

    // MARK: - Reconnect (D4)

    /// Decide what to send after a reconnect, given the Pico's own
    /// `last_processed_seq` — which is authoritative over anything the
    /// phone believed, because it reflects what the kernel actually
    /// consumed.
    public func resumePlan(picoLastProcessedSeq: UInt16,
                           resumeStatus: CuePicoWire.Status) -> ResumePlan {
        guard resumeStatus == .ok, !ringOverflowed else { return .fullRestream }

        let backlog = pending.filter { $0.seq > picoLastProcessedSeq }
        // A hole between what the Pico consumed and what we still hold
        // cannot be replayed in order, so do not try to paper over it.
        if let first = backlog.first, first.seq != picoLastProcessedSeq &+ 1 {
            return .fullRestream
        }
        if backlog.isEmpty { return .replay([]) }

        // Re-flag every replayed step non-actuating: the rider is past
        // these zones by now, and a burst of stale cues is exactly the
        // noisy cueing NFR-001 forbids.
        let flagged = backlog.compactMap { entry -> Data? in
            var payload = entry.payload
            let flagIndex = payload.startIndex + 2
            payload[flagIndex] |= CuePicoWire.StepFlag.catchup
            if var record = records[entry.seq] {
                // Any earlier report for this step is void — it will be
                // reported again after the replay. Because the aggregates
                // are derived from these fields rather than accumulated,
                // clearing them IS the rollback; there is no counter left
                // to forget to adjust, which is what went wrong twice.
                // Mark it replayed: from here on its non-actuation is
                // intentional (NFR-001), not a cue that failed to reach
                // the rider, and unactuatedHeadUps must not count it.
                record.catchup = true
                record.picoType = nil
                record.picoEventID = nil
                record.picoReasonCode = nil
                record.picoLeadTimeS = nil
                record.actuated = nil
                record.actuationDelayUs = nil
                record.diverged = nil
                records[entry.seq] = record
            }
            return payload
        }
        return .replay(flagged)
    }

    // MARK: - Telemetry

    /// Record one STATUS battery reading.
    ///
    /// The caller owns the cadence — this only stamps and stores, so the
    /// sidecar's battery series is exactly the set of readings the link
    /// actually obtained rather than an interpolation over them.
    ///
    /// A zero is dropped rather than recorded: the firmware reports 0 for
    /// "not sampled" (`cue_power_read_mv` before `cue_power_init`, and the
    /// pre-Phase-C builds that had no ADC path at all), and a logged 0 mV
    /// would read as a flat cell — the same fabricated-reading problem
    /// `batteryMillivolts` avoids by mapping 0 to nil for display.
    public func record(batteryMillivolts mv: UInt16,
                       supply: CuePicoWire.Supply) {
        // Kept whenever EITHER half carries information. The millivolts
        // alone used to gate this, which silently discarded the supply
        // label when the device's ADC timed out — and the supply is the
        // half D5 actually reads. A USB stretch whose readings all timed
        // out would then vanish from the series and let an otherwise
        // battery-powered ride claim it never saw USB.
        guard mv != 0 || supply != .unknown else { return }
        let tMs = order.last.flatMap { records[$0]?.tMs } ?? 0
        batterySamples.append(PicoBatterySample(tMs: tMs,
                                                batteryMv: mv == 0 ? nil : mv,
                                                supply: supply))
    }

    /// Whether the device ran on its own cell for the whole ride — the
    /// D5 criterion. Three outcomes, because there are three:
    ///
    /// - `true`  — every sample said battery. The claim is established.
    /// - `false` — at least one sample said USB. The claim is refuted,
    ///             and the ride does not count as an endurance test.
    /// - `nil`   — nothing was sampled, or something was sampled but the
    ///             device could not tell (no radio, so no VBUS read).
    ///             The claim is unmade, which is not the same as failed.
    ///
    /// Collapsing the last two into `false` would report a ride as having
    /// failed a criterion it was never able to attempt.
    public var batteryPoweredThroughout: Bool? {
        guard !batterySamples.isEmpty else { return nil }
        if batterySamples.contains(where: { $0.supply == .usb }) { return false }
        guard batterySamples.allSatisfy({ $0.supply == .battery }) else {
            return nil
        }
        return true
    }

    // MARK: - Export

    /// Per-step evidence in send order — the artifact the D5 acceptance
    /// gate reads ("zero shadow divergences", "every HEAD_UP actuated").
    public var stepRecords: [PicoStepRecord] {
        order.compactMap { records[$0] }
    }

    /// Steps the phone decided HEAD_UP but the Pico never reported
    /// actuating — the "decided but never reached the rider" set.
    ///
    /// Catch-up steps are excluded: their non-actuation is the deliberate
    /// NFR-001 behaviour, not a delivery failure, and counting them would
    /// inflate the very number the D5 gate uses to decide whether cues
    /// are reaching the rider.
    public var unactuatedHeadUps: [PicoStepRecord] {
        stepRecords.filter { !$0.catchup && $0.shadowType == 1 && $0.actuated != true }
    }

    public func exportSidecar() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PicoSidecar(
            rideIDHash: rideIDHash,
            divergenceCount: divergenceCount,
            reportedCount: reportedCount,
            orphanReportCount: orphanReportCount,
            ringOverflowed: ringOverflowed,
            batteryStartMv: batterySamples.compactMap(\.batteryMv).first,
            batteryEndMv: batterySamples.compactMap(\.batteryMv).last,
            batteryPoweredThroughout: batteryPoweredThroughout,
            battery: batterySamples,
            steps: stepRecords))
    }

    /// The per-ride artifact the D5 gate reads.
    ///
    /// The aggregates reconcile exactly against the per-step records:
    ///     divergence_count == orphan_report_count
    ///                         + steps.filter { diverged == true }.count
    /// The orphan term is why the identity needs stating — a report for a
    /// seq the phone never sent has no step record to appear in, so a gate
    /// that recomputed divergences from `steps` alone would undercount.
    /// Exported explicitly so the sidecar is self-checking rather than
    /// asking the reader to trust an aggregate.
    struct PicoSidecar: Codable {
        let rideIDHash: UInt32
        let divergenceCount: Int
        let reportedCount: Int
        /// Reports for a seq this ride never sent — a sequence-level
        /// disagreement, counted in divergence_count but absent from steps.
        let orphanReportCount: Int
        let ringOverflowed: Bool
        /// First and last of `battery`, so "did the battery survive the
        /// ride?" is answerable from the header. Derived rather than
        /// tracked separately, for the same reason the counters above are:
        /// a header that can disagree with the series it summarises is a
        /// gate reading its own bookkeeping bug.
        ///
        /// Both nil when no reading landed — an absent field says "not
        /// measured", which is the distinction D5's evidence needs and a
        /// zero would destroy.
        let batteryStartMv: UInt16?
        let batteryEndMv: UInt16?
        /// D5: a validation ride must run on the 18650. Millivolts cannot
        /// establish that on this carrier — VSYS is unpowered off USB
        /// (#165) — so the supply flag is what the gate actually reads.
        let batteryPoweredThroughout: Bool?
        let battery: [PicoBatterySample]
        let steps: [PicoStepRecord]

        enum CodingKeys: String, CodingKey {
            case rideIDHash = "ride_id_hash"
            case divergenceCount = "divergence_count"
            case reportedCount = "reported_count"
            case orphanReportCount = "orphan_report_count"
            case ringOverflowed = "ring_overflowed"
            case batteryStartMv = "battery_start_mv"
            case batteryEndMv = "battery_end_mv"
            case batteryPoweredThroughout = "battery_powered_throughout"
            case battery
            case steps
        }
    }
}
