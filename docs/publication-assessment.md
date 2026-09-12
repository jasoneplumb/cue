# Publication assessment after exact ablation verification

Assessment date: 2026-09-12. Code base: `66702ed`, plus the verification fix
and regenerated synthetic results in this change.

## Verdict

Cue remains a plausible engineering experience report or research demonstrator.
The defensible contribution is field-checkable execution consistency and
measurement of policy/delivery boundaries. A new cycling-warning concept,
improved rider safety, and effective personalization are not established.
The corrected tool strengthens the evidence process; it does not validate the
historical private field results retroactively.

## Closely related study and source limits

Kapousizis et al., *How do cyclists experience a context-aware prototype warning
system?*, Journal of Cycling and Micromobility Research 3 (2025), 100051,
[DOI](https://doi.org/10.1016/j.jcmr.2024.100051).
The [university publication record](https://research.utwente.nl/en/publications/how-do-cyclists-experience-a-context-aware-prototype-warning-syst/)
confirms 46 participants, three rides per participant, and reported improvements
in perceived safety and speed behavior. The final journal PDF returned HTTP 403.

The author's [full thesis, chapter 6](https://www.interregnorthsea.eu/sites/default/files/2024-11/Thesis_Georgios_Kapousizis-compressed.pdf)
was read as the detailed study account, not assumed identical to the final
article. It reports 46 recruited, 41 analyzed surveys, and 38 complete GPS
participants; a fixed 3.4 km route; baseline first; and equipment-dependent
audio/tactile order. Warnings use zone/speed transitions, visual information,
headphones or gloves. Table 6.3 reports speed decreases of 0.44 km/h at baseline,
1.22 with audio, and 1.42 with tactile. Section 6.4.5 discusses audibility and
implementation limitations. These are chapter-version details pending comparison
with the final journal text.

## What changes in Cue's positioning

The overlap weakens broad novelty claims about context-aware cyclist warnings,
speed-dependent logic, limiting distraction, or finding delivery difficulties.
Cue should cite this study as related work and build on its research questions.

My interpretation: Cue's strongest opportunity is to improve the evidence chain
used to evaluate warning systems. A future study can separately count policy
decisions, transport acknowledgements, physical outputs, rider recognition,
and behavioral responses. Agreement at one boundary must not be promoted into
success at all subsequent boundaries.

The chapter's baseline-first design leaves route familiarity as a possible
confound. Its speed changes do not establish fewer crashes, and its separate
within-condition significance tests do not by themselves establish a treatment
contrast. A Cue behavioral study should counterbalance conditions where feasible
and model repeated observations within riders and locations. These are methodological
recommendations, not a reanalysis of the authors' participant data.

## What the corrected ablations establish

See [the regenerated tables](ablation-demo-results.md). All six synthetic traces
pass normal replay verification before any table is printed. The tool now rejects
changed recorded event IDs, reason codes, lead times, timestamps/types, and missing
recorded HEAD_UPs. Optional omitted NONE decisions retain schema semantics.

The most revealing result is that every variant emits 23 cues, yet their timing
can differ substantially. Aggregate count is therefore insufficient evidence of
policy equivalence. The new full-decision comparison makes this distinction
explicit. Memory and threshold/cooldown removal have zero observed effect in this
demo; that does not establish ineffectiveness under other inputs.

The time-window experiment measures adherence to a calculated distance/speed
window. It is not an independent measurement of time until actual zone entry or
human response. Replay also holds the recorded trajectory fixed; it cannot
predict how a rider would change speed after receiving a different warning.

## Minimum publishable next evidence

Update: [host fault-injection evidence](fault-injection.md) now records ten
directed scenarios, including same-size kernel drift and incomplete-coverage
blind spots. This strengthens the characterization of the contract's limits.
The field corpus remains unavailable; its re-verification is still pending.

1. Re-run the fixed script on the private field corpus and release a privacy-reviewed
   replay dataset with trace, kernel, configuration and firmware provenance.
2. Inject transport loss, duplicate reports, reset and same-size firmware mismatch;
   measure detection coverage, latency, and recovery. The current comparison is
   after actuation, not an actuation veto or proof of policy correctness.
3. Measure physical output and actual zone entry independently, keeping attempted,
   delivered, perceived and behavior-changing cues as separate denominators.
4. Use held-out rides for policy evaluation. If claiming rider benefit, add multiple
   riders, controlled conditions and participant-level uncertainty estimates.

Suggested scope: *Field-Checked Decision Equivalence for Wearable Warning Systems*.
An engineering report can explain the shared kernel, replay contract, fault
experiments and negative results. A behavioral effectiveness paper requires the
additional human study. No first-of-kind claim is established by this comparison.
