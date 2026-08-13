# RFC 0001: Project Name

- **Status:** Accepted (provisional — repo rename is one command if revisited)
- **Date:** 2026-07-08

## Context

The project needs a repo/product name. Existing repos follow a pattern of
short, lowercase, coined or compound names (infobento, taginhood, agenticaster,
phasebot, arcscope, qsitu, tux). The system has two identities in tension:

1. **The demonstrator** — a cycling safety cue (bike-specific, consumer-flavored).
2. **The reusable asset** — an edge-AI sensor-fusion pipeline with a portable
   cue-policy kernel and MCU migration path (vendor-facing).

## Candidates

| Name         | For                                                                                   | Against                                                                                     |
| ------------ | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **cue**      | The load-bearing noun of the whole design (`CueDecision`, cue policy, `HEAD_UP` cue); shortest possible; names the pattern, not just the bike demo; placeholder dir already existed | Extremely generic; collides with the CUE configuration language in search/conversation; says nothing about edge/cycling |
| **edgecue**  | Mirrors infobento's compound construction (where-it-runs + what-it-delivers); captures both the MCU story and the cue; likely unique/brandable | Slightly abstract; "edge" is a crowded marketing prefix in the MCU world                     |
| **ridecue**  | Concrete and evocative for the demo; instantly explains itself to a cyclist            | Undersells the vendor-facing reusable pattern; awkward if the pattern generalizes beyond riding |
| **headup**   | Matches the `HEAD_UP` cue type; "heads-up before the squeeze"                          | Reads as HUD (head-up display) to embedded audiences; generic                                |
| **squeeze**  | Names the core detected event (`COMPOSITE_SQUEEZE_ZONE`); memorable                    | Names the problem, not the product; hard-tied to the cycling demo                            |
| **cuekernel**| Names the actual reusable deliverable (portable cue-policy kernel)                      | Dull as a demo brand; too narrow — the repo also holds the app, replay, and field-test assets |

## Decision

**cue.** An empty `~/github/cue/` placeholder directory was created immediately
after the design bundle was downloaded, indicating existing intent. It names
the pattern rather than the bike demo, matching the design docs' framing that
cycling is the demonstrator and the cue pipeline is the asset. The CUE-language
collision is acceptable for a private repo; if the project goes public or
vendor-facing under its own brand, **edgecue** is the recommended fallback
(`gh repo rename` preserves redirects).

## Consequences

- GitHub repo: `jasoneplumb/cue` (private).
- The vendor-facing product name in outreach materials remains
  "Context-Aware Cycling Safety Cue" per the design record; the repo name is
  internal.
