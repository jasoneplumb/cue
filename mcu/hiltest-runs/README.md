# hiltest-runs — committed on-target pass artifacts

Each file here is one complete run of the on-target portability certificate
(`make -C mcu hiltest-archive PORT=...`): a provenance header (UTC time, repo
HEAD, board, port, toolchain), the full hiltest output, and a `result:`
trailer. Naming: `<utc-timestamp>-<short-sha>.log`.

Commit passing runs — the point is a dated, reviewable record that the gate
passed, not just that the gate exists. A failing run exits nonzero and is
renamed `*.FAILED.log`, which `.gitignore` here keeps unstageable even under
`git add -A`; re-run after fixing and commit the pass.

Re-archive after any kernel or firmware change that reaches the board
(the same trigger as the plain `hiltest` regression rule in
`mcu/pico-cue/README.md`).
