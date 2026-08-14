/*
 * Intent: Fuzz harness for replay/json_mini.h — the hand-rolled JSON
 *         tokenizer is the public repo's primary untrusted-input surface
 *         (every replay trace passes through it), so it gets a fuzzer.
 * Context: Build with clang -fsanitize=fuzzer,address,undefined (see
 *          fuzz/Makefile). -DFUZZ_STANDALONE builds a file-driven main for
 *          toolchains without libFuzzer (Apple clang): it replays the
 *          checked-in traces through the harness under ASan/UBSan.
 * Pattern: After a successful parse, the harness walks the token tree with
 *          jm_skip/jm_obj_get/jm_streq/jm_get_ll so the query helpers are
 *          fuzzed too (and so -Werror sees every static helper used).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json_mini.h"

#define FUZZ_TOK_CAP 4096

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static JmTok toks[FUZZ_TOK_CAP];
  /* Clean slate every iteration: stale tokens from a prior input must not
   * mask an out-of-range walk caused by a corrupt size field. */
  memset(toks, 0, sizeof(toks));
  long n = jm_parse((const char *)data, (long)size, toks, FUZZ_TOK_CAP);
  if (n <= 0) {
    return 0;
  }
  /* Exercise the query helpers over whatever parsed. */
  const char *js = (const char *)data;
  long i = 0;
  while (i < n) {
    const JmTok *t = &toks[i];
    if (t->type == JM_OBJECT) {
      (void)jm_obj_get(js, toks, i, "samples");
    } else if (t->type == JM_STRING) {
      (void)jm_streq(js, t, "HEAD_UP");
    } else if (t->type == JM_PRIMITIVE) {
      long long v;
      (void)jm_get_ll(js, t, &v);
    }
    long next = jm_skip(toks, i);
    if (next <= i) {
      break; /* defensive: a non-advancing skip would spin forever */
    }
    i = next;
  }
  return 0;
}

#ifdef FUZZ_STANDALONE
int main(int argc, char **argv) {
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "rb");
    if (f == NULL) {
      fprintf(stderr, "cannot open %s\n", argv[a]);
      return 2;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)len);
    if (buf == NULL || fread(buf, 1, (size_t)len, f) != (size_t)len) {
      fclose(f);
      free(buf);
      fprintf(stderr, "cannot read %s\n", argv[a]);
      return 2;
    }
    fclose(f);
    LLVMFuzzerTestOneInput(buf, (size_t)len);
    free(buf);
    printf("ok %s\n", argv[a]);
  }
  return 0;
}
#endif
