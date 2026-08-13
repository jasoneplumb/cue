// Intent: CoreBluetooth central for the Cue Ride Service (RFC 0006 D3) —
//         the app-target transport under CuePicoLink's transport-free
//         protocol logic. Scans for the Pico, opens a session, writes the
//         steps PicoStreamer packs, and feeds DECISION notifies back to it
//         for the shadow comparison (D2).
// Context: This is the only file in the MCU path that touches
//          CoreBluetooth, exactly as PhoneWatchLink is the only file that
//          touches WCSession — the protocol logic stays in the package
//          where `swift test` reaches it without hardware.
// Pattern: @MainActor and callback-based, matching the rest of the app
//          layer. Nothing here decides anything about cueing: it moves
//          bytes and reports link state. A cue reaches the rider because
//          the PICO's kernel decided it, not because this class delivered
//          a message (D2) — so a dropped link costs cues, never
//          correctness.
import CoreBluetooth
import CueKernel
import CuePicoLink
import CueRideEngine
import Foundation

@MainActor
final class PicoBLELink: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case idle
        case unsupported
        case unauthorized
        case poweredOff
        case scanning
        case connecting
        /// Connected and subscribed, but no ride session open yet.
        case ready
        case riding
        /// Terminal for this ride: the Pico's kernel state is laid out
        /// differently than ours, so every step would diverge (D6).
        case incompatible(picoStateSize: UInt16)
    }

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var lastError: String?
    /// Surfaced on the ride screen so a divergence is visible during the
    /// ride, not just in the post-ride sidecar (D2).
    @Published private(set) var divergenceCount = 0
    /// Battery millivolts as the device last reported them, or nil when
    /// unknown. The firmware reports 0 for "not sampled", and 0 maps to nil
    /// here rather than being displayed — a fabricated 0 V would read as a
    /// dead battery. Refreshed on the cadence in `stepsSinceBatteryRead`,
    /// and recorded into the ride's sidecar for the D5 gate.
    ///
    /// What this number means depends on the WuKong's supply topology,
    /// which is measured, not assumed — see `cue_power.c` and RFC 0006 D5.
    @Published private(set) var batteryMillivolts: UInt16?

    /// The phone's own `sizeof(CuePolicyState)`, used as the D6 tripwire
    /// against what the Pico reports.
    private let expectedStateSize = UInt16(CuePolicy.stateSize)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var stepChar: CBCharacteristic?
    private var decisionChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?

    /// Steps since the last STATUS read — the battery sampling cadence.
    ///
    /// STATUS is a plain read characteristic: `cue_ble.c` stores its CCCD
    /// but never notifies on it, so subscribing achieved nothing and the
    /// connect-time read was the only reading the phone ever took. The
    /// displayed battery froze at its first value and a ride recorded no
    /// series at all, which is why D5's "battery survives each ride" had
    /// no evidence path (#165). The firmware refreshes its own cached
    /// sample every 10 s while connected, so a read is at most that stale.
    private var stepsSinceBatteryRead = 0
    private static let batteryReadStepInterval = 60

    private var streamer: PicoStreamer?
    /// Steps written but not yet answered by the ATT write response, in
    /// send order. See `acknowledge` in PicoStreamer for why the response
    /// (not the notify) is the acknowledgement signal.
    private var inFlight: [UInt16] = []
    private var wantsSession = false

    private let serviceUUID = CBUUID(string: CuePicoWire.UUIDString.service)
    private let controlUUID = CBUUID(string: CuePicoWire.UUIDString.control)
    private let stepUUID = CBUUID(string: CuePicoWire.UUIDString.step)
    private let decisionUUID = CBUUID(string: CuePicoWire.UUIDString.decision)
    private let statusUUID = CBUUID(string: CuePicoWire.UUIDString.status)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Ride lifecycle

    /// Begin a ride. Safe to call before the link is up: the session opens
    /// as soon as the Pico is connected and subscribed.
    func beginRide(config: CuePolicyConfig) {
        let streamer = PicoStreamer(rideIDHash: PicoStreamer.makeRideIDHash(),
                                    config: config)
        self.streamer = streamer
        divergenceCount = 0
        wantsSession = true
        inFlight.removeAll()
        stepsSinceBatteryRead = 0
        // Open the battery series at ride start rather than waiting a
        // minute for the first cadence read, so `battery_start_mv` means
        // the start of the ride.
        readBattery()
        if case .ready = state {
            openSession()
        } else {
            startScanIfPossible()
        }
    }

    func endRide() {
        wantsSession = false
        if let peripheral, let controlChar {
            peripheral.writeValue(CuePicoWire.packSessionStop(),
                                  for: controlChar, type: .withResponse)
        }
        // Close the battery series on the ride's actual end. Best-effort,
        // not a dependency: the read is async, and the sidecar is exported
        // from finishReview() after the rider grades cues — a human-scale
        // delay it will comfortably beat. If it somehow does not land, the
        // last cadence sample stands as `battery_end_mv`, at most a minute
        // early, rather than the export blocking on telemetry.
        readBattery()
        if case .riding = state { state = .ready }
    }

    /// The per-ride evidence file for the D5 gate. nil when no ride ran.
    func exportSidecar() throws -> Data? { try streamer?.exportSidecar() }

    var unactuatedHeadUpCount: Int { streamer?.unactuatedHeadUps.count ?? 0 }

    /// Stream one kernel step. Called from the ride loop via
    /// `RideEngine.onStep`, with the exact inputs and output of that step.
    func send(step context: RideStepContext) {
        guard case .riding = state,
              let streamer, let peripheral, let stepChar else { return }
        guard let payload = streamer.makeStep(sample: context.sample,
                                              events: context.events,
                                              memory: context.memory,
                                              shadowDecision: context.decision)
        else {
            // Unreachable in practice: RideEngine caps a step at
            // `maxEventsPerStep` upstream of both kernels (RFC 0006 D3).
            // If it is ever reached, `nextSeq` was NOT advanced, so the
            // sequence is still coherent and the Pico is expecting exactly
            // what we will send next — doing nothing costs one step's
            // policy update, whereas resyncing would reset the Pico's
            // kernel while the shadow keeps its accumulated state and turn
            // one missed step into divergence on every step after it.
            lastError = "step exceeded the event cap; step not sent"
            return
        }
        let seq = CuePicoWire.seq(ofStep: payload)
        inFlight.append(seq)
        peripheral.writeValue(payload, for: stepChar, type: .withResponse)

        // Battery telemetry rides the step counter rather than its own
        // timer: steps arrive at 1 Hz, so this is "about once a minute"
        // without a second lifecycle to start, invalidate, and leak. The
        // samples carry real `t_ms`, so an irregular step cadence shows up
        // in the series instead of being papered over by a wall clock.
        stepsSinceBatteryRead += 1
        if stepsSinceBatteryRead >= Self.batteryReadStepInterval {
            stepsSinceBatteryRead = 0
            readBattery()
        }
    }

    /// Fire the actuator without involving either kernel — the on-device
    /// analog of the debug test cue (RFC 0006 D3).
    func fireTestCue() {
        guard let peripheral, let controlChar else { return }
        peripheral.writeValue(CuePicoWire.packTestCue(), for: controlChar,
                              type: .withResponse)
    }

    // MARK: - Internals

    /// Request one STATUS read. Silently does nothing when the link is
    /// down — a ride that loses the link loses battery samples for that
    /// stretch, which the `t_ms` gap in the series shows honestly.
    private func readBattery() {
        guard let peripheral, let statusChar else { return }
        peripheral.readValue(for: statusChar)
    }

    private func startScanIfPossible() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    private func openSession() {
        guard wantsSession, let streamer, let peripheral, let controlChar
        else { return }
        peripheral.writeValue(streamer.sessionStartPayload(), for: controlChar,
                              type: .withResponse)
    }

    /// Recover a link whose step sequence the Pico will no longer accept.
    ///
    /// Deliberately NOT a SESSION_STOP + SESSION_START: that resets the
    /// Pico's kernel to its initial state while the phone's shadow keeps
    /// everything it has accumulated, so every step afterwards diverges —
    /// and those divergences are manufactured by the recovery, not found
    /// by it, which is precisely the NFR-003 signal the shadow exists to
    /// give. Dropping the link instead routes into the reconnect path,
    /// which sends SESSION_RESUME and replays the un-acked backlog from
    /// the Pico's own last_seq. That is D4's recovery, and it preserves
    /// kernel state on both sides.
    private func resyncBySeq() {
        guard let peripheral else { return }
        inFlight.removeAll()
        central.cancelPeripheralConnection(peripheral)
    }

    private func handleSessionAck(_ data: Data) {
        guard let streamer, let ack = CuePicoWire.unpackSessionAck(data) else {
            return
        }
        guard streamer.validate(sessionAck: ack,
                                expectedStateSize: expectedStateSize) else {
            // A width mismatch means the two kernels would disagree from
            // the first step, so there is nothing useful to stream into.
            // Stop rather than produce divergences that say nothing about
            // the policy (D6).
            state = .incompatible(picoStateSize: ack.stateSize)
            lastError = "pico kernel state is \(ack.stateSize) B, expected "
                + "\(expectedStateSize) B — firmware and app are out of sync"
            wantsSession = false
            return
        }
        state = .riding
        lastError = nil
    }

    private func handleResumeAck(_ data: Data) {
        guard let streamer, let ack = CuePicoWire.unpackResumeAck(data),
              let peripheral, let stepChar else { return }
        switch streamer.resumePlan(picoLastProcessedSeq: ack.lastProcessedSeq,
                                   resumeStatus: ack.status) {
        case .fullRestream:
            openSession()
        case .replay(let payloads):
            state = .riding
            for payload in payloads {
                inFlight.append(CuePicoWire.seq(ofStep: payload))
                peripheral.writeValue(payload, for: stepChar, type: .withResponse)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

// The manager is created with `queue: .main`, so every delegate callback
// already arrives on the main queue — hence @preconcurrency conformance
// with main-actor-isolated methods rather than nonisolated ones hopping
// through a Task. The hop is not merely unnecessary: write responses must
// be folded into `inFlight` in arrival order, which an async hop does not
// guarantee, and CoreBluetooth's types are non-Sendable so they cannot
// cross an isolation boundary anyway.
extension PicoBLELink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if case .idle = state { startScanIfPossible() }
            else if case .poweredOff = state { startScanIfPossible() }
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        controlChar = nil; stepChar = nil; decisionChar = nil; statusChar = nil
        inFlight.removeAll()
        batteryMillivolts = nil // a stale reading is worse than none
        // The ride is not over just because the link dropped — the
        // Pico keeps the kernel state, so reconnecting and resuming is
        // the whole point of D4. This is a targeted reconnect to a known
        // peripheral, not a scan, and the status row should not claim
        // otherwise mid-ride.
        state = .connecting
        central.connect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension PicoBLELink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        guard let service = peripheral.services?
            .first(where: { $0.uuid == serviceUUID }) else {
            lastError = "pico-cue is missing the Cue Ride Service"
            return
        }
        peripheral.discoverCharacteristics(
            [controlUUID, stepUUID, decisionUUID, statusUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case controlUUID: controlChar = characteristic
            case stepUUID: stepChar = characteristic
            case decisionUUID: decisionChar = characteristic
            case statusUUID: statusChar = characteristic
            default: break
            }
        }
        // stepChar is required too: without it the link would still reach
        // .ready and every send() would return silently, so a firmware
        // build that dropped or renamed STEP would present as a ride that
        // simply never streams — the case where the diagnostic matters most.
        guard let decisionChar, let controlChar, stepChar != nil else {
            lastError = "pico-cue service is missing a characteristic"
            return
        }
        // Subscribe before opening the session: a decision notify that
        // arrived before we were listening would be lost, and the
        // shadow comparison would see a step that never got answered.
        peripheral.setNotifyValue(true, for: decisionChar)
        peripheral.setNotifyValue(true, for: controlChar)
        // STATUS is telemetry, not on the cue path. Read, never subscribed:
        // the firmware does not notify on it (see `stepsSinceBatteryRead`),
        // so a setNotifyValue here would look like live telemetry while
        // delivering exactly one value.
        readBattery()
    }

    func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            lastError = "subscribe failed: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == decisionUUID else { return }
        if case .connecting = state { state = .ready }
        if case .scanning = state { state = .ready }
        // Reconnecting mid-ride resumes rather than restarting, so the
        // Pico's kernel keeps the state it already has (D4).
        if wantsSession, let streamer {
            if streamer.hasStarted, let controlChar {
                // Reconnecting mid-ride: resume so the Pico keeps the
                // kernel state it already has rather than restarting.
                peripheral.writeValue(streamer.resumePayload(),
                                      for: controlChar, type: .withResponse)
            } else {
                openSession()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case decisionUUID:
            streamer?.handle(decisionReport: data)
            divergenceCount = streamer?.divergenceCount ?? 0
        case statusUUID:
            guard let status = CuePicoWire.unpackStatus(data) else { return }
            batteryMillivolts = status.batteryMillivolts == 0
                ? nil : status.batteryMillivolts
            // Recorded whenever a streamer exists, including the read
            // issued from endRide() — that one is the ride's closing
            // sample and lands while the streamer is still alive for the
            // export in finishReview().
            streamer?.record(batteryMillivolts: status.batteryMillivolts,
                             supply: status.supply)
        case controlUUID:
            guard let opcode = data.first else { return }
            if opcode == CuePicoWire.Opcode.sessionAck {
                handleSessionAck(data)
            } else if opcode == CuePicoWire.Opcode.resumeAck {
                handleResumeAck(data)
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == stepUUID else { return }
        guard !inFlight.isEmpty else { return }
        let seq = inFlight.removeFirst()
        if let error {
            // The Pico refused the step, so its kernel did not advance and
            // ours is now ahead. Every later step would be a seq gap and be
            // refused too, so the link has to be re-established — see
            // resyncBySeq() for why that is a reconnect and not a restart.
            lastError = "step \(seq) refused: \(error.localizedDescription)"
            resyncBySeq()
            return
        }
        // The firmware steps the kernel inside the ATT write callback,
        // so the response implies the step was consumed. See
        // PicoStreamer.acknowledge for why that matters.
        streamer?.acknowledge(seq: seq)
    }
}
