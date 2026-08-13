/*
 * Intent: Minimal vendored single-header JSON tokenizer for the replay
 *         harness (FR-010) — no dynamic dependencies, written for this repo.
 * Context: The harness owns all parsing so the kernel stays import-free
 *          (CLAUDE.md module boundaries). Host-side tool: libc is allowed
 *          here, unlike in kernel/.
 * Pattern: jsmn-style token array over the raw text (type + byte range +
 *          child count), filled by recursive descent. Two-pass friendly:
 *          call jm_parse with toks == NULL to count tokens, allocate
 *          exactly, then parse again.
 * Future: None planned — the trace schema is the only format this reads.
 */
#ifndef JSON_MINI_H
#define JSON_MINI_H

#include <errno.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
  JM_UNDEFINED = 0,
  JM_OBJECT,
  JM_ARRAY,
  JM_STRING,
  JM_PRIMITIVE, /* number, true, false, null */
} JmType;

/* start/end are byte offsets into the source text (end is exclusive; for
 * strings the surrounding quotes are excluded). size is the number of
 * key/value pairs (object) or elements (array); 0 for leaves. */
typedef struct {
  JmType type;
  long start;
  long end;
  long size;
} JmTok;

enum {
  JM_ERR_SYNTAX = -1,
  JM_ERR_NOMEM = -2, /* token array too small */
  JM_ERR_DEPTH = -3, /* nesting beyond JM_MAX_DEPTH */
};

#define JM_MAX_DEPTH 32

typedef struct {
  const char *js;
  long len;
  long pos;
  JmTok *toks; /* NULL: count tokens only */
  long cap;
  long count;
} JmParser;

static long jm_tok_new(JmParser *p, JmType type, long start) {
  long idx = p->count++;
  if (p->toks != NULL) {
    if (idx >= p->cap) {
      return JM_ERR_NOMEM;
    }
    p->toks[idx].type = type;
    p->toks[idx].start = start;
    p->toks[idx].end = -1;
    p->toks[idx].size = 0;
  }
  return idx;
}

static void jm_skip_ws(JmParser *p) {
  while (p->pos < p->len) {
    char c = p->js[p->pos];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
      break;
    }
    p->pos++;
  }
}

/* Caller guarantees p->js[p->pos] == '"'. Escapes are validated and skipped
 * but NOT decoded: jm_streq compares raw bytes, which is exact for the
 * escape-free enum and key strings the trace schema uses. */
static long jm_parse_string(JmParser *p) {
  long tok;
  p->pos++; /* opening quote */
  tok = jm_tok_new(p, JM_STRING, p->pos);
  if (tok < 0) {
    return tok;
  }
  while (p->pos < p->len) {
    char c = p->js[p->pos];
    if (c == '"') {
      if (p->toks != NULL) {
        p->toks[tok].end = p->pos;
      }
      p->pos++;
      return tok;
    }
    if (c == '\\') {
      p->pos++;
      if (p->pos >= p->len) {
        return JM_ERR_SYNTAX;
      }
      c = p->js[p->pos];
      if (c == 'u') {
        int i;
        for (i = 0; i < 4; i++) {
          p->pos++;
          if (p->pos >= p->len) {
            return JM_ERR_SYNTAX;
          }
          c = p->js[p->pos];
          if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                (c >= 'A' && c <= 'F'))) {
            return JM_ERR_SYNTAX;
          }
        }
      } else if (strchr("\"\\/bfnrt", c) == NULL) {
        return JM_ERR_SYNTAX;
      }
      p->pos++;
    } else if ((unsigned char)c < 0x20) {
      return JM_ERR_SYNTAX; /* raw control character in string */
    } else {
      p->pos++;
    }
  }
  return JM_ERR_SYNTAX; /* unterminated string */
}

/* Number grammar is not validated here; jm_get_ll rejects anything strtoll
 * cannot fully consume, which covers every field the schema defines. */
static long jm_parse_primitive(JmParser *p) {
  long start = p->pos;
  long tok;
  while (p->pos < p->len) {
    char c = p->js[p->pos];
    if (c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' ||
        c == '\n' || c == '\r') {
      break;
    }
    if ((unsigned char)c < 0x20) {
      return JM_ERR_SYNTAX;
    }
    p->pos++;
  }
  if (p->pos == start) {
    return JM_ERR_SYNTAX;
  }
  tok = jm_tok_new(p, JM_PRIMITIVE, start);
  if (tok < 0) {
    return tok;
  }
  if (p->toks != NULL) {
    p->toks[tok].end = p->pos;
  }
  return tok;
}

static long jm_parse_value(JmParser *p, int depth);

static long jm_parse_container(JmParser *p, int depth, char open, char close) {
  long tok = jm_tok_new(p, open == '{' ? JM_OBJECT : JM_ARRAY, p->pos);
  if (tok < 0) {
    return tok;
  }
  if (depth <= 0) {
    return JM_ERR_DEPTH;
  }
  p->pos++; /* opening bracket */
  jm_skip_ws(p);
  if (p->pos < p->len && p->js[p->pos] == close) {
    if (p->toks != NULL) {
      p->toks[tok].end = p->pos + 1;
    }
    p->pos++;
    return tok;
  }
  for (;;) {
    long child;
    jm_skip_ws(p);
    if (open == '{') {
      if (p->pos >= p->len || p->js[p->pos] != '"') {
        return JM_ERR_SYNTAX;
      }
      child = jm_parse_string(p); /* key */
      if (child < 0) {
        return child;
      }
      jm_skip_ws(p);
      if (p->pos >= p->len || p->js[p->pos] != ':') {
        return JM_ERR_SYNTAX;
      }
      p->pos++;
      jm_skip_ws(p);
    }
    child = jm_parse_value(p, depth - 1);
    if (child < 0) {
      return child;
    }
    if (p->toks != NULL) {
      p->toks[tok].size++;
    }
    jm_skip_ws(p);
    if (p->pos >= p->len) {
      return JM_ERR_SYNTAX;
    }
    if (p->js[p->pos] == ',') {
      p->pos++;
      continue;
    }
    if (p->js[p->pos] == close) {
      if (p->toks != NULL) {
        p->toks[tok].end = p->pos + 1;
      }
      p->pos++;
      return tok;
    }
    return JM_ERR_SYNTAX;
  }
}

static long jm_parse_value(JmParser *p, int depth) {
  char c;
  jm_skip_ws(p);
  if (p->pos >= p->len) {
    return JM_ERR_SYNTAX;
  }
  c = p->js[p->pos];
  if (c == '{') {
    return jm_parse_container(p, depth, '{', '}');
  }
  if (c == '[') {
    return jm_parse_container(p, depth, '[', ']');
  }
  if (c == '"') {
    return jm_parse_string(p);
  }
  if (c == '-' || (c >= '0' && c <= '9') || c == 't' || c == 'f' || c == 'n') {
    return jm_parse_primitive(p);
  }
  return JM_ERR_SYNTAX;
}

/* Tokenize one complete JSON document. Returns the token count, or a
 * negative JM_ERR_* code. With toks == NULL only counts (cap ignored). */
static long jm_parse(const char *js, long len, JmTok *toks, long cap) {
  JmParser p;
  long r;
  p.js = js;
  p.len = len;
  p.pos = 0;
  p.toks = toks;
  p.cap = cap;
  p.count = 0;
  r = jm_parse_value(&p, JM_MAX_DEPTH);
  if (r < 0) {
    return r;
  }
  jm_skip_ws(&p);
  if (p.pos != p.len) {
    return JM_ERR_SYNTAX; /* trailing content after the document */
  }
  return p.count;
}

/* Index of the token immediately after subtree i (object keys are STRING
 * tokens interleaved with their value subtrees). */
static long jm_skip(const JmTok *toks, long i) {
  long n, j;
  switch (toks[i].type) {
  case JM_OBJECT:
    j = i + 1;
    for (n = 0; n < toks[i].size; n++) {
      j++; /* key */
      j = jm_skip(toks, j);
    }
    return j;
  case JM_ARRAY:
    j = i + 1;
    for (n = 0; n < toks[i].size; n++) {
      j = jm_skip(toks, j);
    }
    return j;
  default:
    return i + 1;
  }
}

/* Raw-byte string comparison — see the escape note on jm_parse_string. */
static int jm_streq(const char *js, const JmTok *t, const char *s) {
  long n = t->end - t->start;
  return t->type == JM_STRING && (long)strlen(s) == n &&
         memcmp(js + t->start, s, (size_t)n) == 0;
}

/* Token index of the value for `key` in object token `obj`, or -1. */
static long jm_obj_get(const char *js, const JmTok *toks, long obj,
                       const char *key) {
  long j, n;
  if (toks[obj].type != JM_OBJECT) {
    return -1;
  }
  j = obj + 1;
  for (n = 0; n < toks[obj].size; n++) {
    long val = j + 1;
    if (jm_streq(js, &toks[j], key)) {
      return val;
    }
    j = jm_skip(toks, val);
  }
  return -1;
}

/* Extract an integer primitive. Returns 0 on non-integers (floats, true,
 * null, out-of-range) — strtoll must consume the whole token. */
static int jm_get_ll(const char *js, const JmTok *t, long long *out) {
  char buf[32];
  char *endp;
  long n = t->end - t->start;
  if (t->type != JM_PRIMITIVE || n <= 0 || n >= (long)sizeof(buf)) {
    return 0;
  }
  memcpy(buf, js + t->start, (size_t)n);
  buf[n] = '\0';
  errno = 0;
  *out = strtoll(buf, &endp, 10);
  return errno == 0 && endp == buf + n;
}

#endif /* JSON_MINI_H */
