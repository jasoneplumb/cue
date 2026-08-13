# mcu/ build orchestration (RFC 0006). Firmware cross-build needs
# PICO_SDK_PATH (and PICO_TOOLCHAIN_PATH if arm-none-eabi-gcc isn't on
# PATH) set in the environment — see pico-cue/README.md. `test` and
# `hiltest` need no cross toolchain: `test` compiles the replay port
# against the host compiler (mirrors kernel/Makefile, replay/Makefile);
# `hiltest` talks to already-flashed hardware over serial.
CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2

BUILD := build
PICO_CUE := pico-cue
KERNEL := ../kernel
SHARED := shared

PYTHON ?= python3
HILTEST_VENV := $(BUILD)/hiltest-venv

.PHONY: build flash test hiltest hiltest-archive blecheck clean

# Cross-build the firmware. Requires PICO_SDK_PATH in the environment.
build:
	cmake -S $(PICO_CUE) -B $(PICO_CUE)/build -DCMAKE_BUILD_TYPE=Release
	cmake --build $(PICO_CUE)/build -j$$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Flash the just-built UF2. The board must already be in BOOTSEL mode
# (hold BOOTSEL while plugging in USB) — picotool cannot force a device
# running arbitrary firmware into BOOTSEL without a picoboot interface.
flash: build
	picotool load -f $(PICO_CUE)/build/pico_cue.uf2
	picotool reboot

# Host-compiled test of the replay-port protocol logic (no hardware,
# no cross toolchain) — the reproducible anchor behind the on-target
# hiltest below. Mirrors kernel/Makefile's and replay/Makefile's own
# `test` targets.
test: $(BUILD)/test_cue_usb_replay $(BUILD)/test_cue_session $(BUILD)/test_cue_wire \
      $(BUILD)/test_cue_pattern $(BUILD)/test_cue_power
	$(BUILD)/test_cue_usb_replay
	$(BUILD)/test_cue_session
	$(BUILD)/test_cue_wire
	$(BUILD)/test_cue_pattern
	$(BUILD)/test_cue_power

# Cue pattern table (RFC 0006 D7). The table is data the actuator plays
# without further validation, so its invariants — ordering, declared vs
# actual duration, the §12 no-restart rule — are asserted here, on the
# host, rather than on a bike.
$(BUILD)/test_cue_pattern: $(PICO_CUE)/tests/test_cue_pattern.c \
                           $(PICO_CUE)/src/cue_pattern.c \
                           $(PICO_CUE)/src/cue_pattern.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(PICO_CUE)/src -o $@ \
	  $(PICO_CUE)/src/cue_pattern.c $(PICO_CUE)/tests/test_cue_pattern.c

# Supply-level bucketing. cue_power.c's hardware reads are behind
# PICO_BUILD, but the bucketing that decides what the rider is told is
# not — it is pure arithmetic, it needs no board to be wrong, and it WAS
# wrong (#165: a battery-powered ride flashed "low" all the way). Built
# without PICO_BUILD, so this compiles the level logic alone.
$(BUILD)/test_cue_power: $(PICO_CUE)/tests/test_cue_power.c \
                         $(PICO_CUE)/src/cue_power.c \
                         $(PICO_CUE)/src/cue_power.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(PICO_CUE)/src -o $@ \
	  $(PICO_CUE)/src/cue_power.c $(PICO_CUE)/tests/test_cue_power.c

# Golden wire vectors. The same byte vectors are asserted in Swift by
# CuePicoLinkTests, so a change to either encoder that is not made to
# both fails here or in `swift test` (RFC 0006 D3).
$(BUILD)/test_cue_wire: $(PICO_CUE)/tests/test_cue_wire.c \
                        $(SHARED)/cue_wire.h \
                        $(KERNEL)/cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(KERNEL) -I$(SHARED) -o $@ \
	  $(PICO_CUE)/tests/test_cue_wire.c

$(BUILD)/test_cue_session: $(PICO_CUE)/tests/test_cue_session.c \
                           $(PICO_CUE)/src/cue_session.c \
                           $(PICO_CUE)/src/cue_session.h \
                           $(PICO_CUE)/src/cue_pattern.c \
                           $(PICO_CUE)/src/cue_pattern.h \
                           $(SHARED)/cue_wire.h \
                           $(KERNEL)/cue_policy.c $(KERNEL)/cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(KERNEL) -I$(SHARED) -I$(PICO_CUE)/src -o $@ \
	  $(PICO_CUE)/src/cue_session.c $(PICO_CUE)/src/cue_pattern.c \
	  $(KERNEL)/cue_policy.c $(PICO_CUE)/tests/test_cue_session.c

$(BUILD)/test_cue_usb_replay: $(PICO_CUE)/tests/test_cue_usb_replay.c \
                              $(PICO_CUE)/src/cue_usb_replay.c \
                              $(PICO_CUE)/src/cue_usb_replay.h \
                              $(SHARED)/cue_wire.h \
                              $(KERNEL)/cue_policy.c $(KERNEL)/cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(KERNEL) -I$(SHARED) -I$(PICO_CUE)/src -o $@ \
	  $(PICO_CUE)/src/cue_usb_replay.c $(KERNEL)/cue_policy.c \
	  $(PICO_CUE)/tests/test_cue_usb_replay.c

# On-target portability certificate (RFC 0006 D6): streams every trace in
# replay/traces/ to a flashed Pico over USB-CDC and diffs decisions
# against the same goldens replay_cli verifies on the host, then proves
# the comparator itself by streaming a must-diverge fixture. Requires
# PORT= pointing at the board's serial device (already running pico_cue,
# i.e. flashed and rebooted out of BOOTSEL — see `flash` above).
#
# pyserial is the tool's only dependency, and stock macOS/Homebrew
# pythons are PEP 668-managed (a plain `pip install` is refused
# system-wide), so rather than making the operator fight their system
# interpreter this provisions a throwaway venv under build/ on first
# use. An interpreter that already has pyserial — including an explicit
# PYTHON= override — is used as-is and no venv is created.
hiltest:
	@if [ -z "$(PORT)" ]; then \
	  echo "usage: make -C mcu hiltest PORT=/dev/tty.usbmodemXXXX" >&2; \
	  exit 2; \
	fi
	@if $(PYTHON) -c 'import serial' >/dev/null 2>&1; then \
	  HILTEST_PY='$(PYTHON)'; \
	else \
	  if [ ! -x '$(HILTEST_VENV)/bin/python' ]; then \
	    echo "pyserial missing from $(PYTHON) — provisioning $(HILTEST_VENV)"; \
	    $(PYTHON) -m venv '$(HILTEST_VENV)' || exit 1; \
	  fi; \
	  '$(HILTEST_VENV)/bin/python' -c 'import serial' >/dev/null 2>&1 || \
	    { echo "provisioning pyserial in $(HILTEST_VENV)"; \
	      '$(HILTEST_VENV)/bin/pip' install --quiet pyserial || exit 1; }; \
	  HILTEST_PY='$(HILTEST_VENV)/bin/python'; \
	fi; \
	"$$HILTEST_PY" ../tools/cue-hiltest/hiltest.py --port $(PORT) \
	  --traces-dir ../replay/traces \
	  --must-diverge ../replay/tests/config_drift_divergence.json

# Archived on-target certificate: run hiltest and capture the whole run —
# with a provenance header (UTC time, repo HEAD + dirty flag, board, port,
# ARM toolchain if present) and a PASS/FAIL trailer — to a dated log under
# mcu/hiltest-runs/, which is meant to be COMMITTED. This converts "we have
# a gate" into "here is the gate passing on <date> at <sha>". Note the
# header records the repo HEAD at run time; the flashed firmware's own
# identity is whatever the log body's SESSION_ACK line reports.
hiltest-archive:
	@if [ -z "$(PORT)" ]; then \
	  echo "usage: make -C mcu hiltest-archive PORT=/dev/tty.usbmodemXXXX" >&2; \
	  exit 2; \
	fi
	@mkdir -p hiltest-runs; \
	DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	STAMP=$$(echo "$$DATE" | tr ':' '-'); \
	SHA=$$(git rev-parse --short HEAD 2>/dev/null); \
	if [ -z "$$SHA" ]; then \
	  echo "hiltest-archive: git rev-parse failed — cannot stamp a certificate" >&2; \
	  exit 1; \
	fi; \
	HEADSHA=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	LOG=hiltest-runs/$$STAMP-$$SHA.log; \
	FLOG=hiltest-runs/$$STAMP-$$SHA.FAILED.log; \
	PORCELAIN=$$(git status --porcelain 2>/dev/null); RC=$$?; \
	if [ $$RC -ne 0 ]; then DIRTY=" (dirty-state unknown)"; \
	elif [ -n "$$PORCELAIN" ]; then DIRTY=" (dirty)"; \
	else DIRTY=""; fi; \
	{ echo "cue on-target portability certificate (RFC 0006 D6)"; \
	  echo "date_utc: $$DATE"; \
	  echo "repo_head: $$HEADSHA$$DIRTY"; \
	  echo "board: Raspberry Pi Pico W (RP2040, mcu/pico-cue firmware)"; \
	  echo "port: $(PORT)"; \
	  TC=$$(arm-none-eabi-gcc --version 2>/dev/null | head -1); \
	  echo "arm_toolchain: $${TC:-not on PATH at run time}"; \
	  echo "---"; } > $$FLOG; \
	if $(MAKE) --no-print-directory hiltest PORT=$(PORT) >> $$FLOG 2>&1; then \
	  echo "result: PASS" >> $$FLOG; \
	  if mv $$FLOG $$LOG; then \
	    cat $$LOG; \
	    echo "archived: $$(pwd)/$$LOG — commit it"; \
	  else \
	    echo "hiltest-archive: rename to $$LOG failed — pass evidence remains in $$(pwd)/$$FLOG (gitignored)" >&2; \
	    exit 1; \
	  fi; \
	else \
	  echo "result: FAIL" >> $$FLOG; \
	  cat $$FLOG; \
	  echo "archived (FAILED, gitignored — a pass log it is not): $$(pwd)/$$FLOG" >&2; \
	  exit 1; \
	fi

#
# BLE bring-up check (RFC 0006 Phase B1) — the radio-side counterpart to
# hiltest. Needs a flashed board advertising as "pico-cue" and, on macOS,
# a terminal that has been granted Bluetooth access in System Settings >
# Privacy & Security > Bluetooth (without it CoreBluetooth blocks at scan
# time instead of raising, which presents as a hang). Same venv
# provisioning as hiltest, with bleak added.
blecheck:
	@if $(PYTHON) -c 'import bleak' >/dev/null 2>&1; then \
	  BLE_PY='$(PYTHON)'; \
	else \
	  if [ ! -x '$(HILTEST_VENV)/bin/python' ]; then \
	    $(PYTHON) -m venv '$(HILTEST_VENV)' || exit 1; \
	  fi; \
	  '$(HILTEST_VENV)/bin/python' -c 'import bleak' >/dev/null 2>&1 || \
	    { echo "provisioning bleak in $(HILTEST_VENV)"; \
	      '$(HILTEST_VENV)/bin/pip' install --quiet bleak || exit 1; }; \
	  BLE_PY='$(HILTEST_VENV)/bin/python'; \
	fi; \
	"$$BLE_PY" -u ../tools/cue-blecheck/blecheck.py $(BLECHECK_ARGS)

clean:
	rm -rf $(BUILD) $(PICO_CUE)/build
