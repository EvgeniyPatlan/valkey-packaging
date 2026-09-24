#!/usr/bin/env bash
set -euo pipefail
PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PACKAGING_ROOT/lib/assert.sh"
source "$PACKAGING_ROOT/lib/fetch-source.sh"
TARGET="${1:?target required}"
[ -z "${2:-}" ] || { echo "arch argument not yet supported (got: $2)" >&2; exit 2; }
VERSION="$PACKAGE_VERSION"

# The spec's %changelog is the version authority for its own most recent
# entry, not lib/fetch-source.sh's PACKAGE_VERSION. Assert they agree instead
# of silently building a package whose %changelog names a stale version
# (mirrors the same guard in build-deb.sh against debian/changelog).
# (Before this packaging was ported to build from a real release tarball,
# this compared against package.json; there is no local package.json any
# more, so PACKAGE_VERSION is this packaging's own ground truth now.)
#
# The release half of that entry is checked too, not just the version: the
# release is load-bearing now (Obsoletes: valkey-admin-server < %{version}-
# %{release} depends on Release actually being ahead of the last pre-rename
# build), so a %changelog entry whose release disagrees with the spec's own
# Release: tag would silently build a package whose Obsoletes threshold
# doesn't match what the changelog claims was shipped.
SPEC="$PACKAGING_ROOT/rpm/percona-valkey-admin.spec"
CHANGELOG_VERSION_RELEASE="$(awk '/^%changelog/{f=1;next} f && /^\* /{print; exit}' "$SPEC" \
  | sed -E 's/.* - //')"
SPEC_VERSION="${CHANGELOG_VERSION_RELEASE%-*}"
SPEC_RELEASE="${CHANGELOG_VERSION_RELEASE#*-}"
[ "$SPEC_VERSION" = "$VERSION" ] || {
  echo "version mismatch: lib/fetch-source.sh PACKAGE_VERSION=$VERSION rpm/percona-valkey-admin.spec %changelog=$SPEC_VERSION" >&2
  echo "update rpm/percona-valkey-admin.spec %changelog to a $VERSION-<release> entry before building" >&2
  exit 2; }

RELEASE_TAG_RAW="$(grep -m1 '^Release:' "$SPEC" | awk '{print $2}')"
RELEASE_TAG_NUM="$(printf '%s' "$RELEASE_TAG_RAW" | sed -E 's/%\{[^}]*\}//g')"
[ -n "$RELEASE_TAG_NUM" ] || {
  echo "could not parse Release: tag in $SPEC" >&2
  exit 2; }
[ "$SPEC_RELEASE" = "$RELEASE_TAG_NUM" ] || {
  echo "release mismatch: rpm/percona-valkey-admin.spec Release tag=$RELEASE_TAG_NUM %changelog release=$SPEC_RELEASE" >&2
  echo "update rpm/percona-valkey-admin.spec %changelog to a $VERSION-$RELEASE_TAG_NUM entry before building" >&2
  exit 2; }

# Per-target output directory: RPM filenames carry %{?dist} (.el8, .el9, ...)
# but a shared out/ still accumulates every target's package side by side,
# and consumers that glob for "the" rpm have no way to tell them apart.
OUT="$PACKAGING_ROOT/out/$TARGET"
mkdir -p "$OUT"

# Cached across all nine targets -- see lib/fetch-source.sh. rpmbuild never
# fetches Source0 itself (the URL in the spec is provenance, not a fetch
# instruction); a file matching its basename must already be in SOURCES,
# which is what the cp below provides.
TARBALL="$(fetch_source_tarball)"

docker run --rm -i \
  -v "$TARBALL:/sources/valkey-admin-$VERSION.tar.gz:ro" \
  -v "$PACKAGING_ROOT:/packaging:ro" -v "$OUT:/out" \
  -v "$PACKAGING_ROOT/../scripts:/repo-scripts:ro" \
  "valkey-admin-pkg:$TARGET" bash -eus <<SH
mkdir -p /root/rpmbuild/SOURCES /root/rpmbuild/SPECS
cp /sources/valkey-admin-$VERSION.tar.gz /root/rpmbuild/SOURCES/
# Source1 for %sysusers_create_compat: it must exist in SOURCES before
# rpmbuild parses the spec, since that macro expands at spec-parse time.
cp /packaging/rpm/valkey-admin.sysusers /root/rpmbuild/SOURCES/
# The remaining aux files the spec installs (Source2-4) and ships as
# documentation (Source5), plus the build helper it executes (Source6) --
# none of these are in the upstream tarball, so they are ours to supply the
# same way. See rpm/percona-valkey-admin.spec and README.packaging.md.
cp /packaging/rpm/valkey-admin.service /root/rpmbuild/SOURCES/
cp /packaging/rpm/valkey-admin.tmpfiles /root/rpmbuild/SOURCES/
cp /packaging/rpm/valkey-admin.env /root/rpmbuild/SOURCES/
cp /packaging/README.packaging.md /root/rpmbuild/SOURCES/
cp /packaging/common/build-server-payload.sh /root/rpmbuild/SOURCES/
# Source7: the repo-root SBOM generator (scripts/gen-module-sbom.sh). It
# lives one level up from this product directory, outside the /packaging
# mount, so it gets its own read-only mount rather than /packaging's --
# same reasoning as the tarball mount above, just for a file this product
# directory doesn't own.
cp /repo-scripts/gen-module-sbom.sh /root/rpmbuild/SOURCES/
cp /packaging/rpm/percona-valkey-admin.spec /root/rpmbuild/SPECS/
rpmbuild -bb --define "_version $VERSION" /root/rpmbuild/SPECS/percona-valkey-admin.spec
cp /root/rpmbuild/RPMS/*/*.rpm /out/
SH
ls -1 "$OUT"
