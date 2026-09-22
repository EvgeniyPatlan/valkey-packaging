#!/usr/bin/env bash
# Builds the fixture "pre-rename" valkey-admin-server RPM used by
# tests/test-upgrade.sh. No application payload, no npm build, no git or
# network dependency -- see rpm/valkey-admin-fixture.spec in this directory
# for what it ships and why.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGING_ROOT="$(cd "$HERE/../.." && pwd)"
source "$PACKAGING_ROOT/lib/assert.sh"
source "$PACKAGING_ROOT/lib/fetch-source.sh"
TARGET="${1:?target required}"
OUT="${2:?output directory required}"
# Same version as the real package (PACKAGE_VERSION), release 1: the real
# package builds at $PACKAGE_VERSION-2 (rpm/percona-valkey-admin.spec's
# Release: tag), so this fixture at $PACKAGE_VERSION-1 is exactly the
# "hypothetical pre-rename valkey-admin-server" that spec's Obsoletes
# comment describes -- the lowest version-release the Obsoletes clause
# (`< %{version}-%{release}`) must still catch.
VERSION="$PACKAGE_VERSION"
mkdir -p "$OUT"

docker run --rm -i \
  -v "$PACKAGING_ROOT/rpm:/aux:ro" \
  -v "$HERE/rpm:/fixture:ro" \
  -v "$OUT:/out" \
  "valkey-admin-pkg:$TARGET" bash -eus <<SH
mkdir -p /root/rpmbuild/SOURCES /root/rpmbuild/SPECS
cp /aux/valkey-admin.sysusers /aux/valkey-admin.service \
   /aux/valkey-admin.tmpfiles /aux/valkey-admin.env \
   /root/rpmbuild/SOURCES/
cp /fixture/valkey-admin-fixture.spec /root/rpmbuild/SPECS/
rpmbuild -bb --define "_version $VERSION" /root/rpmbuild/SPECS/valkey-admin-fixture.spec
cp /root/rpmbuild/RPMS/*/*.rpm /out/
SH
ls -1 "$OUT"
