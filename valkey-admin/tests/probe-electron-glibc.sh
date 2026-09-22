#!/usr/bin/env bash
# Reports whether the Electron binary can resolve its dynamic deps on a target.
# Usage: probe-electron-glibc.sh <docker-image>
#
# Not part of build.sh test (this filename does not match tests/test-*.sh):
# desktop packaging is not yet built by this suite (see README.packaging.md,
# "Packages" -- percona-valkey-admin is "Not yet packaged"). It is kept as a
# standalone diagnostic, invoked by hand against a specific target image.
#
# There is no adjacent valkey-admin working tree here (see
# README.packaging.md) for this to bind-mount and find a developer's own
# `npm ci`-populated node_modules/electron in, the way it could before this
# packaging was ported to build from a fetched release archive. It now
# fetches/extracts that archive itself into a throwaway source root, same as
# tests/test-server-payload.sh -- but a fresh extraction has no node_modules
# at all (npm ci has never run against it), so this will report PROBE_SKIP
# every time unless something has separately run npm ci in the same source
# root and pointed EXTRACTED_SRC at it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
source "$HERE/../lib/fetch-source.sh"
IMAGE="${1:?docker image required}"

if [ -n "${EXTRACTED_SRC:-}" ]; then
  SRC="$EXTRACTED_SRC"
else
  TARBALL="$(fetch_source_tarball)"
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  extract_source_tarball "$TARBALL" "$SRC"
fi

docker run --rm -v "$SRC:/src:ro" "$IMAGE" sh -c '
  set -e
  (ldd --version 2>&1 | head -1) || true
  # Fixed path from the npm "electron" package layout. Not using find(1):
  # minimal RPM-based images (e.g. rockylinux:8) do not ship findutils,
  # which silently produced a false PROBE_SKIP.
  ELECTRON=/src/node_modules/electron/dist/electron
  if [ ! -f "$ELECTRON" ]; then
    echo "PROBE_SKIP: electron binary not present (run npm ci in the extracted source first; see EXTRACTED_SRC above)"; exit 0
  fi
  # Only treat an actual glibc symbol-version mismatch as a failure, e.g.
  # a line naming GLIBC_2.32 not found (required by ...).
  # Plain "lib*.so => not found" lines are missing GUI deps (GTK, NSS, dbus,
  # cairo, X11, ...) that a real RPM/deb package would pull in via
  # Requires/Depends; they are unrelated to glibc viability and matching on
  # them made even the rockylinux:9 control report PROBE_RESULT: no.
  if ldd "$ELECTRON" 2>&1 | grep -q "GLIBC_"; then
    echo "PROBE_RESULT: no"
    ldd "$ELECTRON" 2>&1 | grep "GLIBC_" | head -10
  else
    echo "PROBE_RESULT: yes"
  fi
'
