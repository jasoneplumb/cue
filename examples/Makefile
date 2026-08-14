CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -pedantic -O2

BUILD := build
KERNEL := ../kernel

.PHONY: test clean

test: $(BUILD)/minimal
	$(BUILD)/minimal

$(BUILD)/minimal: minimal/main.c $(KERNEL)/cue_policy.c $(KERNEL)/cue_policy.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(KERNEL) -o $@ minimal/main.c $(KERNEL)/cue_policy.c

clean:
	rm -rf $(BUILD)
