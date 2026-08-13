CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -pedantic -O2

BUILD := build
KERNEL := ../kernel

.PHONY: test clean

# Both example traces must replay divergence-free; the config-drift fixture
# must exit 1 specifically — divergence, not a malformed-trace error (2) —
# so divergence detection itself is what this asserts (review, PR #7).
# --stats output goes through a file, not a pipe, so a nonzero replay_cli
# exit still fails the recipe; the greps pin known-stable metric lines.
test: $(BUILD)/replay_cli
	$(BUILD)/replay_cli traces/squeeze_loop_baseline.json
	$(BUILD)/replay_cli traces/squeeze_loop_tuned.json
	# Issue #28 regression: a near-pass cues zone 201 (t=2000) then retreats
	# past CUE_POLICY_RETREAT_REFUND_M without entering (budget freed, t=4000);
	# the genuine approach (t=20000) must cue again, not be silenced
	# ALREADY_CUED. Reverting the kernel refund makes t=20000 diverge here.
	$(BUILD)/replay_cli traces/near_pass_refund.json
	$(BUILD)/replay_cli --stats traces/near_pass_refund.json > $(BUILD)/stats_near_pass.out
	grep -F "stats: 2 HEAD_UP cue(s)" $(BUILD)/stats_near_pass.out
	grep -F "stats: lead_time_s min=14 median=14 max=14" $(BUILD)/stats_near_pass.out
	$(BUILD)/replay_cli --stats traces/squeeze_loop_baseline.json > $(BUILD)/stats_baseline.out
	grep -F "stats: 2 HEAD_UP cue(s)" $(BUILD)/stats_baseline.out
	grep -F "stats: lead_time_s min=6 median=6 max=15" $(BUILD)/stats_baseline.out
	grep -F "  outcome too_late: 1" $(BUILD)/stats_baseline.out
	$(BUILD)/replay_cli --stats traces/squeeze_loop_tuned.json > $(BUILD)/stats_tuned.out
	grep -F "stats: 2 HEAD_UP cue(s)" $(BUILD)/stats_tuned.out
	grep -F "stats: lead_time_s min=6 median=6 max=18" $(BUILD)/stats_tuned.out
	grep -F "  outcome useful: 1" $(BUILD)/stats_tuned.out
	$(BUILD)/replay_cli --print --stats traces/squeeze_loop_baseline.json 2>/dev/null; test $$? -eq 2
	$(BUILD)/replay_cli tests/config_drift_divergence.json; test $$? -eq 1
	# RFC 0002 (personal route memory, schema v2): each fixture's recorded
	# cue_decisions is the golden output ONLY the memory-influenced gate
	# produces — a regression in the memory hook diverges here, same
	# mechanism as the schema-v1 fixtures above.
	$(BUILD)/replay_cli traces/personal_memory_unsafe.json
	$(BUILD)/replay_cli traces/personal_memory_suppress.json
	$(BUILD)/replay_cli traces/personal_memory_too_late_bonus.json
	$(BUILD)/replay_cli tests/personal_memory_drift_divergence.json; test $$? -eq 1
	@echo "replay tests OK"

$(BUILD)/replay_cli: replay_main.c json_mini.h $(KERNEL)/cue_policy.c $(KERNEL)/cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I. -I$(KERNEL) -o $@ replay_main.c $(KERNEL)/cue_policy.c

clean:
	rm -rf $(BUILD)
