❯ walkthrough the decision layer key design aspects. describe the reasoning, value proposition, tradeoffs, etc

Here's the walkthrough — each design aspect with why it's shaped that way, what it buys, and what it costs. (Round-2 review on PR #68 runs in the background meanwhile.)

1. A pure step function over caller-owned state

The entire decision layer is one call: cue_policy_step(state, sample, events) → decision, where the caller owns the 420-byte state struct. No allocation, no OS calls, no clocks read, no floating point — integer arithmetic over fixed-width types.

Reasoning: every hidden input is a source of divergence and a porting liability. A function whose only inputs are its arguments can run identically on an iPhone, in a desk CLI, and on a Cortex-M0+ — because there's nothing else it could depend on.

Value: MCU portability by construction (NFR-004), and testability that borders on unfair — the whole decision surface is enumerable.

Tradeoff: the kernel can never be "smart" about anything it isn't handed. Wall-clock time, GPS quality, battery state — all invisible unless someone widens the sample struct, and every widening is a schema version and a migration.

2. Determinism as a contract, not a habit

Same trace + same config → bit-identical decisions, enforced by CI fixtures and (in the Phase 4+ demo) an on-board self-check. Crucially, the inputs are trace-first-class: the trace records the matched segment_id and the observed RouteEvents, and replay feeds those recorded values back — it never re-matches or re-scores.

Reasoning: if replay re-derived anything, every matcher improvement or OSM re-import would rewrite history, and you could never distinguish "the policy changed" from "the world model changed."

Value: this is the product differentiator (the audit/tuning story from the pitch): every "why did it fire?" has a reproducible answer, and every threshold experiment is a controlled diff.

Tradeoff: the recorded-inputs choice creates a known blind spot — replay cannot catch scoring bugs, because the scorer's output is frozen into the trace (the D6 circularity note). That's why the scorer carries its own hand-computed fixture suite as an independent leg. Determinism also bans cheap conveniences: no Date.now(), no float shortcuts, no "roughly the same is fine."

3. Conservative by asymmetry: missed beats noisy

At most one HEAD_UP per route event (FR-004), cooldowns in both time and distance, and every ambiguous situation resolves toward silence: unknown lane count → no event; unmatched GPS → segment 0, no observation; stale queued cue on the watch → discarded, logged as undelivered.

Reasoning: the failure modes are not symmetric. A missed cue costs one opportunity; a false or late or repeated cue costs trust, and habituation destroys the entire mechanism — a tap that's usually noise stops redirecting attention (NFR-001). This is the same law as industrial alerting: the monitor that cries wolf gets unplugged.

Value: the alert stays salient, and the design claim stays honest — it's an attention aid, never a safety guarantee.

Tradeoff: deliberate under-coverage. The sparse-tagged residential climb produces no events even where a squeeze exists; issue #28 showed a near-pass can burn an event's one-cue budget before the real approach. The bet is that the §13 tuning loop and rider markers (RFC 0002) close coverage gaps with evidence, rather than eagerness closing them with noise.

4. An explainable gate, not a score

The policy is a pure conjunction of named gates — severity, confidence, inside-event, speed floor, notice window, budget, cooldowns — and every NONE decision carries the first gate that failed as a reason code. The trace logs suppressed decisions too.

Reasoning: a scalar "cue-worthiness score" would be tunable but unexplainable; a conjunction with reason codes means every decision, including every silence, is a one-word answer.

Value: tuning becomes diagnosis ("40% of suppressions are TOO_EARLY → lower max_notice") instead of gradient-poking. This is also what makes the audit story real — the red LED demo can print why.

Tradeoff: conjunctions are blunt. No partial credit, no "high severity compensates for moderate confidence." If field data ever demands weighing evidence, that's a learned model bolted upstream (adjusting severity/confidence inputs), not inside the gate — which is exactly the MPLAB-ML-compatible seam the pitch sells, but it's a constraint today.

5. Timing is the product metric

The gate's core term is time_to_event = distance_to_start / speed, bounded by a 5–15 s notice window. Not distance — time. And delivery latency (phone→watch) is measured and subtracted from the same budget, with the correction applied as a between-rides config change, never a runtime adjustment.

Reasoning: the rider's need is temporal — enough seconds for a mirror check, few enough that the cue is situationally specific. Distance thresholds would silently mistune across speeds.

Value: one number (lead time) is the whole quality story, and it's measurable at every layer: kernel decision, watch delivery, rider recall. The D6 result — one config change moved 39/40 lead times into the window — is this metric doing its job before any ride.

Tradeoff: division by speed makes the gate sensitive to GPS speed noise near thresholds, and the runtime-adjustment ban means a systematic latency change mid-ride is only corrected after the ride. Accepted: a self-adjusting kernel would diverge from its own trace (NFR-003 beats adaptivity).

6. Perception stays off the chip

Map matching, OSM import, squeeze scoring — all phone-side. Only normalized samples, compact events, and the kernel migrate. The decision layer consumes ~20-byte records, not the world.

Reasoning: perception is heavy, data-hungry, and changes often; decisions are tiny and must be stable. Splitting at the RouteEvent boundary puts the churn where compute is free and the invariant where compute is scarce.

Value: the ~1 KB / 420 B footprint that makes "runs on anything" literal, and a clean vendor story — the decision layer is application-agnostic precisely because it never sees a map, only "event, this far ahead, this severe."

Tradeoff: the kernel is only as good as its observations. A matcher error or scorer miscalibration flows straight through the gate, and the kernel can't sanity-check what it can't see. The mitigation is layered independent testing (matcher tests, scorer fixtures, replay contract) rather than kernel-side defensiveness.

7. Fixed-size everything, with the limits documented

int16 distances, uint8 severity/confidence, a 64-entry ring for "already cued" tracking, a 16-observation-per-sample cap shared with the replay harness, dt clamped at 60 s.

Reasoning: every bound is an MCU-portability requirement and a replay-equivalence requirement (live must never produce what replay can't accept — the facade enforces the 16-cap for exactly this reason).

Value: memory is statically known forever; the trace format equals the wire format equals the struct layout.

Tradeoff: each bound is a documented edge: an event evicted from the ring after 64 newer cues could cue twice (test-documented, ~4.8 km of worst-case zones before it matters); distances clamp at ±32 km; content-derived segment IDs orphan personal history when OSM edits a way — always in the conservative direction (memory reverts to neutral), but a real loss.

The one-paragraph synthesis

The decision layer's value proposition is that it makes the unglamorous half of an alerting product — don't nag, don't be late, be explainable, be reproducible, run anywhere — into a tiny, testable artifact with a physics-grade contract: same inputs, same decisions, forever. Every tradeoff above is the same trade taken repeatedly: give up adaptivity, richness, and cleverness at runtime to gain auditability, portability, and trust — then put the cleverness in the offline loop, where replay makes experiments free and mistakes reversible. That's also why it generalizes: nothing in the gate knows it's about bicycles, and the parts that do know (map, matcher, scorer) were quarantined on the phone from day one.