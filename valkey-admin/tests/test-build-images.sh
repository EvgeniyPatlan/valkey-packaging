#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"

TARGET_COUNT="$(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -cv '^[[:space:]]*$')"

checked=0
while read -r target family image rest; do
  [ -n "$target" ] || continue
  img="valkey-admin-pkg:$target"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "skip: $target image not built (run: build.sh image $target)"
    continue
  fi
  checked=$((checked + 1))
  assert_eq "$(docker run --rm "$img" node -p 'process.versions.node.split(".")[0]')" "22" "$target has node 22"
  tool=rpmbuild
  [ "$family" = "deb" ] && tool=dpkg-buildpackage
  docker run --rm "$img" sh -c "command -v $tool >/dev/null" || fail "$target lacks $tool"
  echo "ok: $target has $tool"
done < <(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -v '^[[:space:]]*$')

# A loop that only ever skips still exits 0 -- and checked>0 alone would
# pass on a run that built only 1 of 9 images, the same "continue past what
# wasn't there" gap the review found here. Require every targets.conf entry
# to have been checked, the same way test-lint.sh does per target, not just
# "at least one was".
assert_count "$checked" "$TARGET_COUNT" "target images (run: build.sh image <target> for every target in targets.conf first)"
