#!/usr/bin/env bash
# Shared upstream-source fetch/cache helper.
#
# This packaging no longer sits inside an adjacent valkey-admin working
# tree (that is how it was built on the downstream/packaging branch it was
# ported from: rpm/build-rpm.sh and deb/build-deb.sh snapshotted the
# checkout next to packaging/ and rpm/percona-valkey-admin.spec's Source0
# was a relative path into that snapshot). Here it builds from a real
# upstream release archive, so:
#
#   - PACKAGE_VERSION is this packaging's own version authority. There is
#     no local package.json to read it from any more; rpm/percona-valkey-admin.spec's
#     %changelog and debian/changelog are still cross-checked against this
#     value by rpm/build-rpm.sh and build-deb.sh, exactly as they were
#     cross-checked against package.json before the port.
#   - fetch_source_tarball caches the downloaded release archive under
#     $PACKAGING_ROOT/.cache so the nine build targets share one download
#     instead of each target re-fetching it.
#   - extract_source_tarball unpacks it with the top-level
#     valkey-admin-$PACKAGE_VERSION/ directory stripped, for callers (DEB
#     build assembly, test-server-payload.sh) that need a plain source
#     root rather than a version-suffixed subdirectory. rpm/build-rpm.sh
#     does not use this: rpmbuild's own %autosetup performs the
#     equivalent extraction from Source0 inside the build container.
set -euo pipefail

PACKAGE_VERSION="1.1.1"

VALKEY_ADMIN_SOURCE_URL_BASE="https://github.com/valkey-io/valkey-admin/archive/refs/tags"

# fetch_source_tarball [cache-dir]
# Downloads (or reuses a cached copy of) the upstream release tarball for
# $PACKAGE_VERSION. Prints the absolute path to the cached file on stdout.
fetch_source_tarball() {
  local cache_dir="${1:-${PACKAGING_ROOT:?PACKAGING_ROOT must be set}/.cache}"
  local tarball="valkey-admin-$PACKAGE_VERSION.tar.gz"
  local dest="$cache_dir/$tarball"
  mkdir -p "$cache_dir"
  if [ -s "$dest" ]; then
    echo "using cached $dest" >&2
  else
    local url="$VALKEY_ADMIN_SOURCE_URL_BASE/v$PACKAGE_VERSION/$tarball"
    echo "fetching $url" >&2
    local tmp="$dest.part"
    curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; echo "failed to download $url" >&2; return 1; }
    mv "$tmp" "$dest"
  fi
  printf '%s\n' "$dest"
}

# extract_source_tarball <tarball> <dest-dir>
# Extracts <tarball> into <dest-dir> (created if missing) with the
# top-level valkey-admin-$PACKAGE_VERSION/ directory stripped, so
# <dest-dir> itself becomes the source root.
extract_source_tarball() {
  local tarball="$1" dest_dir="$2"
  mkdir -p "$dest_dir"
  tar -xzf "$tarball" -C "$dest_dir" --strip-components=1
}
