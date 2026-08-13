CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -pedantic -O2

BUILD := build

.PHONY: test clean

test: $(BUILD)/test_cue_policy
	$(BUILD)/test_cue_policy

$(BUILD)/test_cue_policy: cue_policy.c tests/test_cue_policy.c cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I. -o $@ cue_policy.c tests/test_cue_policy.c

clean:
	rm -rf $(BUILD)
