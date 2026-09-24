#!/usr/bin/env bash
# Assertion helpers plus the targets.conf reader. Sourced by every test.
PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
  echo "ok: $3"
}

assert_file() {
  [ -e "$1" ] || fail "expected file to exist: $1"
  echo "ok: exists $1"
}

assert_mode() {
  local actual
  actual="$(stat -c '%a' "$1")"
  [ "$actual" = "$2" ] || fail "$1: expected mode $2, got $actual"
  echo "ok: mode $2 on $1"
}

assert_owner() {
  local actual
  actual="$(stat -c '%U:%G' "$1")"
  [ "$actual" = "$2" ] || fail "$1: expected owner $2, got $actual"
  echo "ok: owner $2 on $1"
}

# assert_checked <count> <label> -- fails when a discovery-then-iterate
# loop (a glob under nullglob, or a `while read ...; done < <(...)` fed by
# a process substitution) processed zero items. set -e cannot catch this
# on its own: it fires on commands that fail, never on commands that never
# ran, so a loop with nothing to discover still exits 0 -- indistinguishable
# from a loop where every discovered item genuinely passed. Call this once,
# after the loop, on a counter incremented on every real iteration.
assert_checked() {
  local count="$1" label="$2"
  [ "$count" -gt 0 ] || fail "$label: nothing was checked (discovery found zero items)"
  echo "ok: $label ($count checked)"
}

# assert_count <actual> <expected> <label> -- like assert_eq, but numeric
# (-eq, not =): for comparing a processed/discovered count against an
# expected one, where "07" and "7" must compare equal and a non-numeric
# actual value is itself an error rather than a silent string mismatch.
assert_count() {
  local actual="$1" expected="$2" label="$3"
  # An expected count of 0 makes this assertion pass no matter what actual
  # discovery produced (0 -eq 0 is as true as it gets) -- indistinguishable
  # from a caller that meant to require items and instead computed its
  # expectation as zero. Every current and future caller wants a positive
  # count; reject the vacuous case explicitly instead of trusting it.
  [ "$expected" -gt 0 ] || fail "$label: expected count is zero"
  [ "$actual" -eq "$expected" ] || fail "$label: expected $expected, got $actual"
  echo "ok: $label ($actual)"
}

# targets_field <target-name> <column: family|image|desktop>
targets_field() {
  local name="$1" col="$2"
  awk -v n="$name" -v c="$col" '
    /^#/ || /^[[:space:]]*$/ { next }
    $1 == n {
      if (c == "family")       print $2
      else if (c == "image")   print $3
      else if (c == "desktop") print $4
    }
  ' "$PACKAGING_ROOT/targets.conf"
}
