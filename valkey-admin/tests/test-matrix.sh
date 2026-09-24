#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"

checked=0
while read -r name family image rest; do
  [ -n "$name" ] || continue
  assert_file "$PACKAGING_ROOT/docker/Dockerfile.$name"
  docker image inspect "valkey-admin-pkg:$name" >/dev/null 2>&1 \
    || fail "image not built for target: $name (run: build.sh image $name)"
  echo "ok: image present for $name"
  checked=$((checked + 1))
done < <(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -v '^[[:space:]]*$')

# The while/process-substitution loop above executes zero times, not a
# failure, if targets.conf can't be read -- set -e never sees that as an
# error. Without this, a missing/unreadable targets.conf would exit 0
# having asserted nothing about any target's image.
assert_checked "$checked" "targets.conf entries"
