#!/usr/bin/env python3
"""
Intent: BLE bring-up check for the Cue Ride Service (RFC 0006 D3) — the
        radio-side counterpart to tools/cue-hiltest (USB). Scans for
        pico-cue, opens a session, streams steps, and verifies each
        DECISION notification against what the kernel must decide,
        including the D4 idempotent-retry rule.
Context: What issue #153's B1 acceptance step describes doing by hand in
         nRF Connect / LightBlue, automated so it is repeatable.
Pattern: Host-side tool. The struct formats all use '<' so Python packs
         without padding, matching mcu/shared/cue_wire.h's packed wire
         sizes exactly; --selftest asserts that agreement with no radio
         and no hardware.

macOS note: CoreBluetooth is gated behind a per-application TCC
permission. The FIRST run must come from a terminal that has been
granted Bluetooth access (System Settings > Privacy & Security >
Bluetooth); without it the process blocks silently at scan time rather
than raising, which looks like a hang.

Usage:
  make -C mcu blecheck            # live check against a flashed board
  python3 blecheck.py --selftest  # offline wire-size assertions only

  # Fire the candidate actuation patterns for a back-to-back comparison
  # (RFC 0006 D7). No ride and no session needed — TEST_CUE drives the
  # actuator only, never the kernel.
  make -C mcu blecheck BLECHECK_ARGS="--pattern 3"
  make -C mcu blecheck BLECHECK_ARGS="--patterns --gap 4"
"""
import argparse
import asyncio
import struct
import sys

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # --selftest must work without the BLE stack installed
    BleakClient = BleakScanner = None

SVC = "85bf0001-c87e-4346-8a6c-440b3e57f451"
CONTROL = "85bf0002-c87e-4346-8a6c-440b3e57f451"
STEP = "85bf0003-c87e-4346-8a6c-440b3e57f451"
DECISION = "85bf0004-c87e-4346-8a6c-440b3e57f451"
STATUS = "85bf0005-c87e-4346-8a6c-440b3e57f451"

# Wire v2 (#164, #165). Mirrored from cue_wire.h: the delay field kept its
# offset and width across the version change, so nothing about the layout
# distinguishes a v1 peer from a v2 one — only this number does.
PROTO_VERSION = 2
STATUS_SIZE = 6
SUPPLY_NAMES = {0: "unknown", 1: "usb", 2: "battery"}

decisions = []
controls = []


def pack_config(sev, conf, minn, maxn, cds, cdm, spd):
    return struct.pack("<BBHHHHH", sev, conf, minn, maxn, cds, cdm, spd)


def pack_sample(t_ms, speed, seg):
    # lat/lon/heading zeroed by contract (RFC 0006 D3)
    return struct.pack("<IiiHHI", t_ms, 0, 0, speed, 0, seg)


def pack_event(eid, seg, sev, conf, reasons, d_start, d_end):
    return struct.pack("<IBIBBHhh", eid, 1, seg, sev, conf, reasons, d_start, d_end)


def pack_step(seq, flags, sample, events=(), memory=None):
    out = struct.pack("<HBB", seq, flags, len(events)) + sample
    for e in events:
        out += e
    if memory is not None:
        out += memory
    return out


def selftest():
    """Assert the Python wire encoding matches cue_wire.h's packed sizes.
    A mismatch here would otherwise only appear as a rejected write on
    hardware, so it is worth catching without a board attached."""
    cases = [
        ("SAMPLE", len(pack_sample(1000, 500, 42)), 20),
        ("EVENT", len(pack_event(7, 42, 200, 200, 1, 50, 120)), 17),
        ("MEMORY", len(struct.pack("<IBB", 42, 2, 0)), 6),
        ("CONFIG", len(pack_config(128, 128, 5, 15, 15, 75, 4)), 12),
        (
            "SESSION_START",
            len(struct.pack("<BBI", 0x01, PROTO_VERSION, 0) + pack_config(128, 128, 5, 15, 15, 75, 4)),
            18,
        ),
        (
            "STEP(1 event)",
            len(pack_step(1, 0, pack_sample(1000, 500, 42),
                          [pack_event(7, 42, 200, 200, 1, 50, 120)])),
            4 + 20 + 17,
        ),
        # The DECISION report is the only format this tool DECODES rather
        # than encodes, so a layout change would otherwise surface only
        # against live hardware. Built here exactly as the firmware does
        # (seq | t_ms | CueDecision | actuated | actuation_delay_us).
        (
            "DECISION_REPORT",
            len(struct.pack("<HI", 1, 1000)
                + struct.pack("<BIBh", 1, 7, 0, 10)
                + struct.pack("<BH", 1, 0)),
            17,
        ),
        # STATUS gained the supply byte in v2. Pinned here because the
        # live path length-checks against it, and a stale constant would
        # turn a healthy board into "reflash it".
        ("STATUS", len(struct.pack("<HBHB", 1, 0, 5037, 1)), STATUS_SIZE),
    ]
    failures = 0
    for name, got, want in cases:
        if got != want:
            print(f"FAIL {name}: {got} bytes, want {want}")
            failures += 1
        else:
            print(f"ok   {name}: {got} bytes")

    # The protocol version is pinned as a VALUE, and separately from the
    # size cases above because it is not a size — the version byte is one
    # byte wide whatever it holds, so every length case passes at v1 and
    # v2 alike. Without this, a bump in cue_wire.h that missed this file
    # would fail the C and Swift suites and still pass --selftest,
    # surfacing only against hardware at SESSION_START. The same literal
    # is asserted in test_cue_wire.c and CuePicoWireTests.swift.
    if PROTO_VERSION != 2:
        print(f"FAIL PROTO_VERSION: {PROTO_VERSION}, want 2")
        failures += 1
    else:
        print(f"ok   PROTO_VERSION: {PROTO_VERSION}")

    # Round-trip the report through the same parser the live path uses,
    # so the field OFFSETS are checked and not just the total length.
    report = (struct.pack("<HI", 42, 9000) + struct.pack("<BIBh", 1, 7, 0, 12)
              + struct.pack("<BH", 1, 250))
    seq, t_ms = struct.unpack("<HI", report[:6])
    dtype, eid, reason, lead = struct.unpack("<BIBh", report[6:14])
    actuated, delay = struct.unpack("<BH", report[14:17])
    if (seq, t_ms, dtype, eid, reason, lead, actuated, delay) != (
            42, 9000, 1, 7, 0, 12, 1, 250):
        print("FAIL DECISION_REPORT: field offsets do not round-trip")
        failures += 1
    else:
        print("ok   DECISION_REPORT: field offsets round-trip")
    print("blecheck selftest: " + ("FAILED" if failures else "wire sizes agree with cue_wire.h"))
    return 1 if failures else 0


async def main():
    print("scanning for pico-cue...")
    dev = await BleakScanner.find_device_by_name("pico-cue", timeout=15.0)
    if dev is None:
        print("FAIL: pico-cue not found while scanning")
        return 1
    print(f"found: {dev.name} [{dev.address}]")

    async with BleakClient(dev) as client:
        print(f"connected, mtu={client.mtu_size}")
        svcs = [s.uuid.lower() for s in client.services]
        if SVC not in svcs:
            print(f"FAIL: Cue Ride Service missing; saw {svcs}")
            return 1
        print("service present")

        await client.start_notify(DECISION, lambda _h, d: decisions.append(bytes(d)))
        await client.start_notify(CONTROL, lambda _h, d: controls.append(bytes(d)))

        status = await client.read_gatt_char(STATUS)
        if len(status) != STATUS_SIZE:
            # A v1 firmware serves 5 bytes here. Say so plainly rather
            # than unpacking a short buffer into plausible nonsense.
            print(f"FAIL: STATUS is {len(status)} B, want {STATUS_SIZE} "
                  "— firmware predates wire v2, reflash it")
            return 1
        fw, state, batt, supply = struct.unpack("<HBHB", status)
        print(f"status: fw=0x{fw:04x} state={state} battery_mv={batt} "
              f"supply={SUPPLY_NAMES.get(supply, supply)}")

        # SESSION_START: proto 1, ride hash, spec-default config w/ min_speed 4
        cfg = pack_config(128, 128, 5, 15, 15, 75, 4)
        await client.write_gatt_char(
            CONTROL, struct.pack("<BBI", 0x01, PROTO_VERSION, 0xABCDEF01) + cfg,
            response=True
        )
        await asyncio.sleep(0.6)
        if not controls:
            print("FAIL: no SESSION_ACK indication")
            return 1
        op, st, fwv, state_size = struct.unpack("<BBHH", controls[-1])
        print(f"SESSION_ACK op=0x{op:02x} status={st} fw=0x{fwv:04x} state_size={state_size}")
        if op != 0x81 or st != 0:
            print("FAIL: session not accepted")
            return 1
        if state_size != 420:
            print(f"FAIL: state_size {state_size} != 420 (width tripwire)")
            return 1

        # Step 1: 5 m/s, zone 50 m ahead -> 10 s lead, inside [5,15] -> HEAD_UP
        ev = pack_event(7, 42, 200, 200, 1, 50, 120)
        await client.write_gatt_char(
            STEP, pack_step(1, 0, pack_sample(1000, 500, 42), [ev]), response=True
        )
        await asyncio.sleep(0.6)

        # Step 2: same event closer -> already cued (FR-004), no second cue
        ev2 = pack_event(7, 42, 200, 200, 1, 40, 110)
        await client.write_gatt_char(
            STEP, pack_step(2, 0, pack_sample(3000, 500, 42), [ev2]), response=True
        )
        await asyncio.sleep(0.6)

        if len(decisions) < 2:
            print(f"FAIL: expected 2 DECISION notifies, got {len(decisions)}")
            return 1

        ok = True
        for i, d in enumerate(decisions[:2]):
            seq, t_ms = struct.unpack("<HI", d[:6])
            dtype, eid, reason, lead = struct.unpack("<BIBh", d[6:14])
            actuated, delay = struct.unpack("<BH", d[14:17])
            print(f"DECISION seq={seq} t_ms={t_ms} type={dtype} event={eid} "
                  f"reason={reason} lead={lead} actuated={actuated} "
                  f"delay_us={delay}")
            if i == 0 and not (dtype == 1 and eid == 7 and lead == 10 and actuated == 1):
                print("  FAIL: expected HEAD_UP with 10 s lead, actuated")
                ok = False
            if i == 1 and not (dtype == 0 and reason == 8 and actuated == 0):
                print("  FAIL: expected NONE/ALREADY_CUED, not actuated")
                ok = False

        # Duplicate seq must NOT re-step the kernel (idempotent retry).
        before = len(decisions)
        await client.write_gatt_char(
            STEP, pack_step(2, 0, pack_sample(3000, 500, 42), [ev2]), response=True
        )
        await asyncio.sleep(0.6)
        if len(decisions) == before + 1 and decisions[-1] == decisions[before - 1]:
            print("duplicate seq: cached report replayed, kernel untouched")
        else:
            print("FAIL: duplicate seq did not replay the cached report")
            ok = False

        # A full 16-event step is 302 B, which exceeds the ATT payload
        # (MTU-3) on any MTU below 305 — so this is the path that forces
        # BTstack's prepare/execute long write. Untested, it would fail
        # only on a dense-event stretch of a real ride.
        max_events = [pack_event(100 + i, 42, 10, 10, 1, 900, 950) for i in range(16)]
        big = pack_step(3, 0, pack_sample(5000, 500, 42), max_events)
        att_payload = client.mtu_size - 3
        print(f"max STEP is {len(big)} B; ATT payload is {att_payload} B "
              f"({'long write required' if len(big) > att_payload else 'fits in one PDU'})")
        before = len(decisions)
        try:
            await client.write_gatt_char(STEP, big, response=True)
            await asyncio.sleep(0.8)
            if len(decisions) == before + 1:
                seq, _t = struct.unpack("<HI", decisions[-1][:6])
                print(f"max-size step accepted (seq={seq})")
            else:
                print("FAIL: max-size step produced no DECISION")
                ok = False
        except Exception as e:  # noqa: BLE001 - report, don't crash the check
            print(f"FAIL: max-size step write raised: {e}")
            ok = False

        await client.write_gatt_char(CONTROL, bytes([0x03]), response=True)
        print("session stopped")
        return 0 if ok else 1


# Upper bound on the probe below, not a copy of the firmware's count. The
# firmware is the authority on how many candidates exist: a hardcoded
# count here would silently skip a newly added pattern, and the primary
# comparison workflow would fail with no indication.
CUE_PATTERN_PROBE_LIMIT = 32

# GENERIC_ACK opcode and the status meaning "index outside the table".
ACK_GENERIC = 0x83
STATUS_OK = 0
STATUS_BAD_PATTERN = 6


async def fire_patterns(client, acks, indices, gap):
    """Fire each candidate in turn so they can be judged back-to-back.

    The whole reason the device exists is perceptibility, and which
    rendering a rider actually notices is an empirical question — so this
    plays them on demand instead of asking anyone to reflash between
    candidates (RFC 0006 D7, issue #154).

    `indices` may be an open-ended iterator: firing stops at the first
    BAD_PATTERN, which is how the count is discovered from the firmware
    rather than duplicated here. A refused index actuates nothing, so the
    probe that ends the sweep is silent.
    """
    fired = 0
    for i in indices:
        before = len(acks)
        await client.write_gatt_char(CONTROL, bytes([0x04, i]), response=True)
        await asyncio.sleep(0.4)
        if len(acks) == before:
            print(f"FAIL: no ack for TEST_CUE pattern {i}")
            return 1
        op, st = struct.unpack("<BB", acks[-1][:2])
        if op != ACK_GENERIC:
            print(f"FAIL: unexpected ack opcode 0x{op:02x}")
            return 1
        if st == STATUS_BAD_PATTERN:
            if fired == 0:
                print(f"FAIL: firmware has no pattern {i}")
                return 1
            break  # past the end of the firmware's table
        if st != STATUS_OK:
            print(f"FAIL: pattern {i} refused, status={st}")
            return 1
        print(f"pattern {i}: fired")
        fired += 1
        # The gap is what makes this a comparison rather than a medley:
        # long enough for the pattern to finish and the ear to reset.
        await asyncio.sleep(gap)

    print(f"{fired} pattern(s) fired")
    return 0


async def connect_and_fire(indices, gap):
    print("scanning for pico-cue...")
    dev = await BleakScanner.find_device_by_name("pico-cue", timeout=15.0)
    if dev is None:
        print("FAIL: pico-cue not found while scanning")
        return 1
    print(f"found: {dev.name} [{dev.address}]")

    async with BleakClient(dev) as client:
        acks = []
        await client.start_notify(CONTROL, lambda _h, d: acks.append(bytes(d)))
        return await fire_patterns(client, acks, indices, gap)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1].strip())
    parser.add_argument("--selftest", action="store_true",
                        help="offline wire-size assertions; no radio needed")
    parser.add_argument("--pattern", type=int, metavar="N",
                        help="fire actuation pattern N and exit")
    parser.add_argument("--patterns", action="store_true",
                        help="fire every candidate in turn for comparison")
    parser.add_argument("--gap", type=float, default=3.0, metavar="S",
                        help="seconds between patterns (default 3). Keep it "
                             "above ~2.5 s: the longest candidate runs 1.6 s "
                             "and firing the next one early replaces the "
                             "rendering in flight, so the candidates blur "
                             "into each other instead of being comparable")
    args = parser.parse_args()

    if args.selftest:
        sys.exit(selftest())
    if BleakScanner is None:
        print("ERROR: pyserial's BLE counterpart 'bleak' is required for the "
              "live check (make -C mcu blecheck provisions it).", file=sys.stderr)
        sys.exit(2)

    if args.patterns:
        # Open-ended: the firmware ends the sweep with BAD_PATTERN, so
        # adding a candidate needs no change here.
        sys.exit(asyncio.run(
            connect_and_fire(range(CUE_PATTERN_PROBE_LIMIT), args.gap)))
    if args.pattern is not None:
        if args.pattern < 0:
            print("ERROR: pattern index must be non-negative", file=sys.stderr)
            sys.exit(2)
        # No upper bound checked here either — an out-of-range index is
        # reported by the firmware, which is the only thing that knows.
        sys.exit(asyncio.run(connect_and_fire([args.pattern], 0.0)))
    sys.exit(asyncio.run(main()))
