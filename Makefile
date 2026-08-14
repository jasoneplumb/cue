# Convenience entry points for a fresh clone. Each subdirectory Makefile
# stays authoritative; this only sequences them. `swift test` (CueKernel
# facade) and the iOS app build remain separate — see CLAUDE.md's quality
# gate. Fuzzing lives in fuzz/ (needs clang with libFuzzer; see fuzz/Makefile).
.PHONY: test demo-corpus clean

test:
	$(MAKE) -C kernel test
	$(MAKE) -C replay test
	$(MAKE) -C mcu test
	$(MAKE) -C examples test

# Synthetic, coordinate-free ride corpus under demo-rides/ (gitignored) so
# tools/cue-results/aggregate.py and tools/cue-ablation/ablate.py run on a
# fresh clone without the operator's private field data (NFR-005).
demo-corpus:
	python3 tools/cue-demo-corpus/generate.py

clean:
	$(MAKE) -C kernel clean
	$(MAKE) -C replay clean
	$(MAKE) -C mcu clean
	$(MAKE) -C examples clean
	rm -rf demo-rides
