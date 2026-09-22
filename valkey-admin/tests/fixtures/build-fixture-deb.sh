#!/usr/bin/env bash
# Builds the fixture "pre-rename" valkey-admin-server DEB used by
# tests/test-upgrade-deb.sh. No application payload, no npm build, no git
# or network dependency -- see deb/debian/control in this directory for
# what it ships and why.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_ROOT="$(cd "$HERE/../.." && pwd)"
TARGET="${1:?target required}"
OUT="${2:?output directory required}"
mkdir -p "$OUT"

WORK="$(mktemp -d)"
cleanup() {
  docker run --rm -v "$WORK:/work" "valkey-admin-pkg:$TARGET" \
    chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# "aux" matches this repo's own vocabulary for these same two files (see
# rpm/build-rpm.sh's SOURCES copy comments and README.packaging.md) rather
# than the pre-rename source tree's "packaging/systemd" + "packaging/config"
# split, which exists nowhere in this repo.
mkdir -p "$WORK/src/aux"
cp "$PACKAGING_ROOT/rpm/valkey-admin.service" "$WORK/src/aux/"
cp "$PACKAGING_ROOT/rpm/valkey-admin.env" "$WORK/src/aux/"
cp -a "$HERE/deb/debian" "$WORK/src/debian"

docker run --rm -i -v "$WORK:/work" -v "$OUT:/out" "valkey-admin-pkg:$TARGET" bash -eus <<SH
cd /work/src
dpkg-buildpackage -us -uc -b
cp /work/*.deb /out/
SH
ls -1 "$OUT"
