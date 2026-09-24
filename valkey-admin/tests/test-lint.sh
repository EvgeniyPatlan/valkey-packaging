#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"

# out/ is per-target (out/<target>/...). rpmlint only ships in
# the el8 and el9 images and lintian only in the DEB images, so every rpm
# is linted through the el9 image and every deb through the debian12
# image, never through each target's own image.
#
# Iterated per target named in targets.conf, not "glob out/ for every
# *.rpm/*.deb, count them, and compare the sums to two derived totals" --
# summed totals can match by coincidence (two artifacts in one target's
# directory and zero in another still sums right) and previously did carry
# that risk. A per-target loop can't: each named target is required to
# have produced exactly the one artifact its family expects.
shopt -s nullglob

checked=0
while read -r target family image rest; do
  [ -n "$target" ] || continue
  outdir="$PACKAGING_ROOT/out/$target"

  case "$family" in
    rpm)
      artifacts=("$outdir"/*.rpm)
      assert_count "${#artifacts[@]}" 1 "$target: rpm artifacts in out/$target"
      rpm="${artifacts[0]}"
      base="$(basename "$rpm")"
      # rpmlint 1.11 (as shipped in the el9 image) predates the
      # --config/TOML rewrite; its filter file is loaded with -f. See the
      # note atop rpm/rpmlint.toml.
      #
      # rpmlint's exit code alone is not trustworthy here: it exits 0 both
      # when a package cannot even be read ("0 packages ... checked", e.g.
      # a truncated/corrupt rpm) and when only W-level findings remain
      # (the badness threshold that would turn warnings into a nonzero
      # exit is off by default). Capture the output and require the
      # literal "1 packages and 0 specfiles checked; 0 errors, 0
      # warnings." summary line -- that exact line is only ever printed
      # when exactly one package was actually read and it produced zero
      # findings of either severity.
      out="$(docker run --rm -v "$PACKAGING_ROOT:/pkg:ro" valkey-admin-pkg:el9 \
        rpmlint -f /pkg/rpm/rpmlint.toml "/pkg/out/$target/$base" 2>&1)" || true
      echo "$out"
      echo "$out" | grep -qF '1 packages and 0 specfiles checked; 0 errors, 0 warnings.' \
        || fail "rpmlint did not report a clean single-package check for $target/$base"
      echo "ok: rpmlint clean for $target/$base"
      ;;
    deb)
      artifacts=("$outdir"/*.deb)
      assert_count "${#artifacts[@]}" 1 "$target: deb artifacts in out/$target"
      deb="${artifacts[0]}"
      base="$(basename "$deb")"
      # --fail-on error,warning: lintian's exit code otherwise only
      # reflects E-level tags, so an unsuppressed W-level finding would
      # exit 0.
      docker run --rm -v "$PACKAGING_ROOT:/pkg:ro" valkey-admin-pkg:debian12 \
        lintian --suppress-tags-from-file /pkg/debian/percona-valkey-admin-server.lintian-overrides \
        --fail-on error,warning "/pkg/out/$target/$base"
      echo "ok: lintian clean for $target/$base"
      ;;
    *)
      fail "$target: unknown family '$family' in targets.conf"
      ;;
  esac
  checked=$((checked + 1))
done < <(grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -v '^[[:space:]]*$')

# Same reasoning as test-matrix.sh: this while/process-substitution loop
# executes zero times, not a failure, if targets.conf can't be read.
assert_checked "$checked" "packaging targets linted"

echo "ok: lint test passed ($checked target(s))"
