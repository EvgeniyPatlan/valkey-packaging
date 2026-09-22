#!/usr/bin/env bash
set -euo pipefail
PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGING_ROOT/lib/assert.sh"
source "$PACKAGING_ROOT/lib/fetch-source.sh"
TARGET="${1:?target required}"
[ -z "${2:-}" ] || { echo "arch argument not yet supported (got: $2)" >&2; exit 2; }
VERSION="$PACKAGE_VERSION"
# Per-target output directory: DEB filenames carry no distro suffix at all,
# so a shared out/ would have each target silently overwrite the last one's
# package. Keep every target's artifact addressable on its own.
OUT="$PACKAGING_ROOT/out/$TARGET"
mkdir -p "$OUT"

# debian/changelog is the version authority for the DEB, not lib/fetch-source.sh
# alone -- assert they agree instead of silently building a mismatched version.
# (Before this packaging was ported to build from a real release tarball,
# this compared against package.json; there is no local package.json any
# more, so lib/fetch-source.sh's PACKAGE_VERSION is this packaging's own
# ground truth now. See README.packaging.md.)
#
# The debian revision half is checked too, not just the upstream version:
# it must track the RPM spec's Release tag, since README.packaging.md
# documents the two builders' version authorities as moving together -- a
# build that left one at a stale release while the other moved on would
# make that documented invariant false silently (exactly the "RPM at -2,
# DEB at -1" mistake this guard exists to catch).
CHANGELOG_TOP="$(sed -n '1p' "$PACKAGING_ROOT/debian/changelog")"
CHANGELOG_VERSION_RELEASE="$(printf '%s' "$CHANGELOG_TOP" | sed -E 's/^[^(]*\(([^)]*)\).*/\1/')"
CHANGELOG_VERSION="${CHANGELOG_VERSION_RELEASE%-*}"
CHANGELOG_RELEASE="${CHANGELOG_VERSION_RELEASE#*-}"
[ "$CHANGELOG_VERSION" = "$VERSION" ] || {
  echo "version mismatch: lib/fetch-source.sh PACKAGE_VERSION=$VERSION debian/changelog=$CHANGELOG_VERSION" >&2
  echo "update debian/changelog to $VERSION-<release> before building" >&2
  exit 2; }

SPEC="$PACKAGING_ROOT/rpm/percona-valkey-admin.spec"
SPEC_RELEASE_TAG_RAW="$(grep -m1 '^Release:' "$SPEC" | awk '{print $2}')"
SPEC_RELEASE_NUM="$(printf '%s' "$SPEC_RELEASE_TAG_RAW" | sed -E 's/%\{[^}]*\}//g')"
[ -n "$SPEC_RELEASE_NUM" ] || {
  echo "could not parse Release: tag in $SPEC" >&2
  exit 2; }
[ "$CHANGELOG_RELEASE" = "$SPEC_RELEASE_NUM" ] || {
  echo "release mismatch: debian/changelog revision=$CHANGELOG_RELEASE rpm/percona-valkey-admin.spec Release tag=$SPEC_RELEASE_NUM" >&2
  echo "the RPM Release and DEB revision must move together (README.packaging.md); update debian/changelog to a $VERSION-$SPEC_RELEASE_NUM entry" >&2
  exit 2; }

# Cached across all nine targets -- see lib/fetch-source.sh.
TARBALL="$(fetch_source_tarball)"

WORK="$(mktemp -d)"
cleanup() {
  docker run --rm -v "$WORK:/work" "valkey-admin-pkg:$TARGET" \
    chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$WORK/src"

# A proper orig tarball, not a working-tree snapshot: this packaging no
# longer lives inside an adjacent valkey-admin checkout, so the DEB source
# package's pristine upstream half is the same release archive the RPM
# side builds from (renamed to the orig tarball convention dpkg-source
# expects for a non-native package; see debian/source/format). The build
# below still runs dpkg-buildpackage with -b (binary only), which does not
# invoke dpkg-source and therefore does not itself require this file to be
# present -- it is produced anyway so the source package's provenance is
# real and reproducible if a source-including build is ever wanted.
cp "$TARBALL" "$WORK/percona-valkey-admin_$VERSION.orig.tar.gz"
extract_source_tarball "$TARBALL" "$WORK/src"

cp -a "$PACKAGING_ROOT/debian" "$WORK/src/debian"

docker run --rm -i -v "$WORK:/work" -v "$PACKAGING_ROOT:/packaging:ro" -v "$OUT:/out" \
  "valkey-admin-pkg:$TARGET" bash -eus <<SH
cd /work/src
dpkg-buildpackage -us -uc -b
cp /work/*.deb /out/
SH
ls -1 "$OUT"
