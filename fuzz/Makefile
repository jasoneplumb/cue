# Fuzzing for the trace-JSON tokenizer (replay/json_mini.h).
#
#   make -C fuzz smoke   — 60 s libFuzzer run seeded with the checked-in
#                          traces (needs clang with libFuzzer: Linux clang
#                          or Homebrew llvm; Apple clang lacks it)
#   make -C fuzz check   — standalone harness under ASan/UBSan over the
#                          checked-in traces (works with Apple clang)
# Plain `=`, not `?=`: make's built-in CC default (`cc`) is always defined,
# so `?=` would never select clang — and gcc's `cc` has no libFuzzer.
# Override on the command line if needed: make CC=... smoke
CC = clang
BASEFLAGS := -std=c99 -Wall -Wextra -Werror -pedantic -O1 -g -I../replay
SAN := -fsanitize=address,undefined -fno-sanitize-recover=all

BUILD := build

.PHONY: smoke check clean

$(BUILD)/fuzz: json_mini_fuzz.c ../replay/json_mini.h
	mkdir -p $(BUILD)
	$(CC) $(BASEFLAGS) $(SAN) -fsanitize=fuzzer -o $@ json_mini_fuzz.c

$(BUILD)/fuzz_standalone: json_mini_fuzz.c ../replay/json_mini.h
	mkdir -p $(BUILD)
	$(CC) $(BASEFLAGS) $(SAN) -DFUZZ_STANDALONE -o $@ json_mini_fuzz.c

smoke: $(BUILD)/fuzz
	mkdir -p $(BUILD)/corpus
	cp ../replay/traces/*.json ../replay/tests/*.json $(BUILD)/corpus/
	$(BUILD)/fuzz -max_total_time=60 -print_final_stats=1 $(BUILD)/corpus

check: $(BUILD)/fuzz_standalone
	$(BUILD)/fuzz_standalone ../replay/traces/*.json ../replay/tests/*.json

clean:
	rm -rf $(BUILD)
