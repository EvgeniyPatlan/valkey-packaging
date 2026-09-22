#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"

assert_eq "$("$HERE/../build.sh" list | wc -l)" "9" "list prints 9 targets"
assert_eq "$("$HERE/../build.sh" list | grep -c '^el9 ')" "1" "el9 is a known target"
assert_eq "$(targets_field el9 family)" "rpm" "el9 is an rpm family target"
assert_eq "$(targets_field debian12 family)" "deb" "debian12 is a deb family target"
assert_eq "$("$HERE/../build.sh" list | awk '$4=="unknown"' | wc -l)" "0" "no target left as desktop=unknown"

if "$HERE/../build.sh" nosuchtarget 2>/dev/null; then
  fail "unknown target must exit non-zero"
fi
echo "ok: unknown target rejected"
