#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/fetch-source.sh"
OUT="${PAYLOAD_OUT:-$(mktemp -d)}"

if [ -z "${PAYLOAD_OUT:-}" ]; then
  # No adjacent valkey-admin working tree to bind-mount any more (see
  # README.packaging.md): fetch/reuse the cached upstream release archive
  # and extract it into a throwaway source root instead.
  TARBALL="$(fetch_source_tarball)"
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  extract_source_tarball "$TARBALL" "$SRC"
  docker run --rm -v "$SRC:/src:ro" -v "$PACKAGING_ROOT/common:/aux:ro" -v "$OUT:/out" valkey-admin-pkg:el9 \
    bash /aux/build-server-payload.sh /src /out
fi

assert_file "$OUT/apps/server/dist/index.cjs"
assert_file "$OUT/apps/metrics/dist/index.cjs"
assert_file "$OUT/apps/metrics/config.yml"
assert_file "$OUT/apps/frontend/dist/index.html"
assert_file "$OUT/node_modules/@valkey/valkey-glide/package.json"
assert_file "$OUT/node_modules/ws/package.json"

# The layout invariant, asserted against the ARTIFACT rather than by string
# arithmetic: the compiled bundle hardcodes these relative paths and there is
# no environment override for the frontend one, so if upstream changes the
# relative depth the payload layout is silently wrong. path.join() of two
# constants can only ever reproduce its own input, which is why this greps
# the bundle instead.
grep -q '\.\./\.\./frontend/dist' "$OUT/apps/server/dist/index.cjs" \
  || fail "server bundle no longer encodes ../../frontend/dist — installed tree layout is invalid"
echo "ok: server bundle encodes ../../frontend/dist"

grep -q '\.\./\.\./metrics/dist/index\.cjs' "$OUT/apps/server/dist/index.cjs" \
  || fail "server bundle no longer encodes ../../metrics/dist/index.cjs — collector spawn path is invalid"
echo "ok: server bundle encodes ../../metrics/dist/index.cjs"

# Nothing from the build toolchain should have leaked in.
[ ! -d "$OUT/node_modules/vite" ] || fail "build-only dependency vite leaked into payload"
echo "ok: no build-only dependencies in payload"
