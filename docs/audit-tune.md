❯ why is replay valuable in terms of tuning and aduits

Because it converts a fleeting real-world moment into a permanent, re-executable experiment. Unpacking that for each use:

Tuning

The field event is the scarce resource; replay makes it reusable. A squeeze-zone approach at 20 mph happens once, lasts seconds, and can't be re-run on demand. Without replay, tuning means: change a threshold, go ride again, hope the same conditions recur, compare from memory. With replay, one recorded ride becomes an inexhaustible test corpus — every past approach, near-miss, and false alarm can be re-decided under any candidate configuration, on a desk, in milliseconds. The D6 work already demonstrated the payoff: the discovery that max_notice_s=12 puts 39/40 lead times inside the spec window came from replaying simulated rides against configurations, not from forty physical rides.

Determinism is what makes the comparison meaningful. If replay were merely approximate — floating-point drift, timing jitter, a re-matched map — you could never tell whether a changed decision came from your config change or from noise in the harness. The bit-exact contract (NFR-003) means the only free variable between two replays is the thing you changed. That turns tuning from anecdote into controlled experiment: same trace + config A vs. config B is a clean diff of decisions, and replay_cli --stats quantifies it (lead-time distributions, suppressions, false alarms against the rider's own reviews[] grades).

It also makes tuning safe. The §13 loop changes config between rides, records it in the trace's policy_config, and never auto-adjusts at runtime — because the moment live behavior can drift from what the trace records, replay stops predicting reality and every downstream conclusion silently rots. Determinism is the property that keeps the tuning loop honest with itself.

Audits

"Why did it fire here?" gets an exact answer, not a reconstruction. When a cue seems wrong — too late, too eager, silent when it shouldn't have been — replay re-executes the identical decision from the recorded inputs and shows the kernel's actual reasoning path (reason bits, computed lead time, budget state). There's no "we think the GPS was probably…" — the trace is the ground truth the kernel saw, and the decision reproduces from it exactly. This is also why the matcher records its output into the trace and replay never re-matches: the audit replays what the ride saw, not what today's map would say.

Regression protection. Every checked-in trace is a frozen contract: any code change that alters even one historical decision fails CI as a divergence. You can refactor the kernel, port it to a new compiler, or move it to an MCU, and the trace corpus certifies that behavior is unchanged — the Phase 4+ demo's red LED is literally this audit running on the target silicon.

And it's why the vendor story works. In industrial settings the audit question has money and liability attached — "why did the alarm not fire before the bearing seized?" A statistical model's answer is a confidence score; a deterministic replay's answer is a reproducible execution. That's the differentiator the catalog scan found missing across TI, Microchip, and Renesas, and it's the second half of the pitch sentence: every decision it ever makes can be replayed bit-for-bit on a desk.

The compact version: tuning needs repeatability to compare fairly, audits need reproducibility to explain truthfully, and deterministic replay is the single mechanism that provides both — which is why it's a design invariant (NFR-003) in this project rather than a debugging convenience.

❯ when does a per-segment notice_bonus_s become a global config change

Personal route memory (RFC 0002 D4) adds +2s to a segment's `notice_bonus_s` per `too_late` review, capped at 8s (four corrections). That cap is the escalation trigger, not a silent ceiling: a segment that's still cueing late after 8s of accumulated per-segment bonus is systematically mis-timed in a way one segment's data can't fix — the underlying `min_notice_s`/`max_notice_s` in `CuePolicyConfig` is wrong for conditions this rider/route sees generally (typical speed, reaction time, watch delivery latency), not just for that one squeeze zone.

The fix at that point is the same replay-driven tuning loop this doc already describes, just aimed at the global config: pull the rides where the segment kept mis-cueing, run `replay_cli --stats` across candidate `min_notice_s`/`max_notice_s` values the way the D6 max_notice_s=12 discovery worked, and land the new default in `CuePolicyConfig` rather than letting individual segments keep accumulating bonus. A segment capped at 8s and still too-late is a signal to open the tuning loop, not a bug in the per-segment bonus mechanism.