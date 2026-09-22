#!/usr/bin/env bash
# Every built artifact under out/ must be at least as new as the newest file
# that can actually change what lands inside a package. This branch has hit
# the same failure mode three times: rebuild, then edit packaging content
# afterward, and the recorded "green" artifacts silently stop attesting to
# HEAD. rpm -qpl / dpkg-deb inspection catches it after the fact; this test
# catches it before anyone trusts the artifact.
#
# This is an mtime comparison, not a content comparison. Touching a stale
# artifact forward makes it pass again with nothing rebuilt, and any
# workflow that restores out/ from a cache or copies artifacts between
# machines without preserving timestamps (a plain `cp` without -p, most CI
# artifact caches) defeats this silently. It only means something in a
# workflow that builds and checks in the same place, which is what
# build.sh test does.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/fetch-source.sh"

# CONTENT_INPUTS: files whose changes can silently alter what a built
# package contains. The operative criterion is "determines package
# content", not "ships inside a package" -- common/build-server-payload.sh
# below is the clearest case: it never ships itself, but its explicit cp
# list is what selects which node_modules subdirs and dist/ outputs reach
# the payload, so it belongs here regardless.
#
# There is no adjacent valkey-admin working tree here (see
# README.packaging.md): the upstream half of package content -- apps/,
# common/ (the compiled JS workspace, not this directory's own common/),
# package.json, package-lock.json, NOTICES, LICENSE -- all arrives as one
# fetched, cached release archive, so that cached archive is the single
# content input standing in for all of it. Its mtime only moves when it is
# freshly downloaded, which only happens when the cache is empty or
# PACKAGE_VERSION changes to a version not yet cached -- exactly "the
# upstream source changed" from this test's point of view.
#
# Deliberately excluded: build.sh, rpm/build-rpm.sh, build-deb.sh, tests/,
# lib/, docker/, targets.conf, rpm/rpmlint.toml, deb/lintian-overrides.
# rpm/build-rpm.sh and build-deb.sh are a real judgment call, not a clean
# case: their fetch/extract calls decide what source material reaches the
# build in the first place, which does influence content in a broad sense.
# They stay out of scope because that selection is coarse (which release
# tarball) rather than a selection of what specifically lands in the
# payload or package metadata -- that selection happens in
# common/build-server-payload.sh and in the spec/control/postinst, all
# covered below. Comparing against everything in this directory would also
# make an unrelated test-script edit invalidate every artifact, which is
# exactly the kind of over-broad guard that gets disabled the first time
# it misfires.
CACHED_TARBALL="$PACKAGING_ROOT/.cache/valkey-admin-$PACKAGE_VERSION.tar.gz"
CONTENT_INPUTS=(
  "$PACKAGING_ROOT/rpm/percona-valkey-admin.spec"
  "$PACKAGING_ROOT/debian"
  "$PACKAGING_ROOT/rpm/valkey-admin.service"
  "$PACKAGING_ROOT/rpm/valkey-admin.sysusers"
  "$PACKAGING_ROOT/rpm/valkey-admin.tmpfiles"
  "$PACKAGING_ROOT/rpm/valkey-admin.env"
  "$PACKAGING_ROOT/common"
  # README.packaging.md ships inside both packages (the spec's
  # "%doc README.packaging.md", debian/percona-valkey-admin-server.docs) --
  # from a built package's perspective this is shipped content, not
  # process documentation, and staled exactly this way once already.
  "$PACKAGING_ROOT/README.packaging.md"
  "$CACHED_TARBALL"
)

# find errors to stderr on a missing path but still emits results for
# every path that DOES exist, and the process substitution below hides
# that exit status from set -e -- so a CONTENT_INPUTS entry that gets
# moved or renamed would silently narrow the input set instead of failing.
# Check every entry exists up front, by name, before trusting find's
# output at all.
for input in "${CONTENT_INPUTS[@]}"; do
  if [ "$input" = "$CACHED_TARBALL" ] && [ ! -e "$input" ]; then
    fail "content input missing: $input -- no build has fetched the $PACKAGE_VERSION source archive yet (run rpm/build-rpm.sh or build-deb.sh for any target first)"
  fi
  [ -e "$input" ] || fail "content input missing: $input -- CONTENT_INPUTS entry moved or renamed"
done

newest_input_time=0
newest_input_path=""
while IFS= read -r -d '' f; do
  t="$(stat -c '%Y' "$f")"
  if [ "$t" -gt "$newest_input_time" ]; then
    newest_input_time="$t"
    newest_input_path="$f"
  fi
done < <(find "${CONTENT_INPUTS[@]}" -type f -print0)

[ -n "$newest_input_path" ] || fail "no content inputs found -- CONTENT_INPUTS is misconfigured"
echo "ok: newest package-content input is $newest_input_path"

TARGET_COUNT="$(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -cv '^[[:space:]]*$')"

checked=0
while read -r target family image rest; do
  [ -n "$target" ] || continue
  outdir="$PACKAGING_ROOT/out/$target"

  shopt -s nullglob
  case "$family" in
    rpm) artifacts=("$outdir"/*.rpm) ;;
    deb) artifacts=("$outdir"/*.deb) ;;
    *) shopt -u nullglob; fail "$target: unknown family '$family' in targets.conf" ;;
  esac
  shopt -u nullglob
  [ "${#artifacts[@]}" -gt 0 ] \
    || fail "$target: no built artifact in out/$target -- build it first (build.sh $target)"

  for artifact in "${artifacts[@]}"; do
    artifact_time="$(stat -c '%Y' "$artifact")"
    [ "$artifact_time" -ge "$newest_input_time" ] \
      || fail "$target: $(basename "$artifact") predates $newest_input_path -- rebuild after packaging content changes"
  done
  echo "ok: $target artifact(s) not older than $newest_input_path"
  checked=$((checked + 1))
done < <(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -v '^[[:space:]]*$')

assert_count "$checked" "$TARGET_COUNT" "targets with provenance-checked artifacts"
