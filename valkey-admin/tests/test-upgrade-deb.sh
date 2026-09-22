#!/usr/bin/env bash
# DEB counterpart to test-upgrade.sh: an install of the pre-rename
# valkey-admin-server package, upgraded in place to
# percona-valkey-admin-server through the new package's
# Provides/Replaces/Conflicts. The RPM side was the only rename upgrade
# path the suite exercised; this closes the same gap for DEB, using the
# same self-contained fixture (tests/fixtures/deb/debian) instead of a git
# worktree or the real pre-rename commit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
TARGET="debian12"
OUT="$PACKAGING_ROOT/out/$TARGET"
# The trailing "|| true" matters under set -euo pipefail: without it, ls
# failing on a no-match glob (exit 2) propagates through the pipe to
# head -1 and, with pipefail, makes this assignment itself exit non-zero --
# which aborts the script right here, silently, before the descriptive
# fail() below ever runs.
NEW_DEB="$(ls "$OUT"/percona-valkey-admin-server_*.deb 2>/dev/null | head -1 || true)"
[ -n "$NEW_DEB" ] || fail "no percona-valkey-admin-server deb in out/$TARGET"

OLDHOLD="$(mktemp -d)"
trap 'rm -rf "$OLDHOLD"' EXIT

bash "$PACKAGING_ROOT/tests/fixtures/build-fixture-deb.sh" "$TARGET" "$OLDHOLD" >/dev/null
OLD_DEB="$(ls "$OLDHOLD"/valkey-admin-server_*.deb 2>/dev/null | head -1 || true)"
[ -n "$OLD_DEB" ] || fail "fixture build produced no valkey-admin-server deb"
echo "ok: built pre-rename fixture valkey-admin-server deb"

IMAGE="debian:12"
docker run --rm -i -v "$OUT:/out:ro" -v "$OLDHOLD:/old:ro" "$IMAGE" bash -eus <<'SH'
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl >/dev/null
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
apt-get install -y --no-install-recommends nodejs >/dev/null

# Install the pre-rename fixture package and act like an operator who has
# been running it for a while: a config edit and data on disk.
apt-get install -y /old/valkey-admin-server_*.deb >/dev/null
dpkg-query -W -f='${Status}' valkey-admin-server 2>/dev/null | grep -q 'installed$' \
  || { echo "FAIL: pre-rename package did not install"; exit 1; }
test -f /usr/lib/valkey-admin-server/marker \
  || { echo "FAIL: pre-rename payload missing before upgrade"; exit 1; }
echo "ok: pre-rename valkey-admin-server installed"

echo "PORT=9999" >> /etc/valkey-admin/valkey-admin.env
echo "operator data" > /var/lib/valkey-admin/operator-marker
echo "ok: operator made a config edit and wrote data before the upgrade"

# The upgrade under test: installing the renamed package over the old one,
# relying on Provides/Replaces/Conflicts to resolve it as a replacement
# rather than a side-by-side install.
apt-get install -y /out/percona-valkey-admin-server_*.deb >/dev/null

# Unlike rpm's Obsoletes, dpkg's Replaces/Conflicts does NOT fully erase the
# obsoleted package on this transition: valkey-admin-server lands in the
# "rc" (deinstalled, config files remaining) state, and "dpkg -s
# valkey-admin-server" keeps exiting 0 -- a "dpkg -s ... && fail" assertion
# would flag a correctly working upgrade as broken. Assert on the dpkg -l
# status field instead, which is what actually distinguishes "still
# installed" (ii) from "removed, config remnants only" (rc).
#
# An empty STATUS_FLAG (dpkg-query prints nothing and exits non-zero for a
# package it has never heard of) is accepted alongside deinstall/unknown:
# it means dpkg forgot the old package entirely, a strictly more thorough
# removal than the rc state this transition currently leaves. A future
# dpkg or debhelper behavior change that fully erases the obsoleted name
# should not fail this test for doing better than required.
STATUS_FLAG="$(dpkg-query -W -f='${Status}' valkey-admin-server 2>/dev/null | awk '{print $1}')"
case "$STATUS_FLAG" in
  deinstall|unknown|"") : ;;
  *) echo "FAIL: valkey-admin-server dpkg status flag is '$STATUS_FLAG', expected deinstall (rc state) or gone entirely"; exit 1 ;;
esac
echo "ok: valkey-admin-server is in rc (deinstalled, config-files-remaining) state or gone entirely, not still installed"

dpkg-query -W -f='${Status}' percona-valkey-admin-server 2>/dev/null | grep -q '^install ok installed$' \
  || { echo "FAIL: percona-valkey-admin-server is not installed after the rename upgrade"; exit 1; }
echo "ok: Replaces/Conflicts resolved valkey-admin-server to percona-valkey-admin-server"

test ! -e /usr/lib/valkey-admin-server \
  || { echo "FAIL: old payload root /usr/lib/valkey-admin-server still present after upgrade"; exit 1; }
test -f /usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs \
  || { echo "FAIL: new payload root /usr/lib/percona-valkey-admin-server missing after upgrade"; exit 1; }
echo "ok: payload root migrated to /usr/lib/percona-valkey-admin-server"

grep -q '^PORT=9999' /etc/valkey-admin/valkey-admin.env \
  || { echo "FAIL: operator edit to valkey-admin.env did not survive the rename upgrade"; exit 1; }
echo "ok: operator edit to valkey-admin.env survived the rename upgrade"

test ! -e /etc/valkey-admin/valkey-admin.env.dpkg-old \
  && test ! -e /etc/valkey-admin/valkey-admin.env.dpkg-dist \
  || { echo "FAIL: stray .dpkg-old/.dpkg-dist next to the live env file after the rename upgrade"; exit 1; }
echo "ok: no stray .dpkg-old/.dpkg-dist next to the live env file"

test -f /var/lib/valkey-admin/operator-marker \
  || { echo "FAIL: /var/lib/valkey-admin contents were lost across the rename upgrade"; exit 1; }
echo "ok: /var/lib/valkey-admin is intact"

# A real hazard, not a hypothetical one: the old package's own postrm is
# still on disk in the rc state, and purging valkey-admin-server runs that
# postrm's purge branch (rm -rf /var/lib/valkey-admin; deluser valkey-admin)
# against whatever currently owns those unbranded paths -- which, after
# this upgrade, is the live, healthy percona-valkey-admin-server install.
# dpkg's conffile tracking is per source package and genuinely protects
# the env file (confirmed below), but /var/lib/valkey-admin and the
# valkey-admin system account are not conffiles and are not protected by
# anything -- the old postrm deletes them unconditionally. This was
# checked against a fixture carrying the real pre-rename postinst/postrm
# (tests/fixtures/deb/debian/valkey-admin-server.post{inst,rm}),
# not the debhelper-boilerplate-only scriptlets a naive fixture would
# carry, which would hide this entirely: see README.packaging.md for the
# operator-facing writeup of this hazard and why it cannot occur in
# practice (the pre-rename DEB was never published).
apt-get purge -y valkey-admin-server >/dev/null

test -f /etc/valkey-admin/valkey-admin.env \
  || { echo "FAIL: purging the obsoleted valkey-admin-server deleted the live env file"; exit 1; }
grep -q '^PORT=9999' /etc/valkey-admin/valkey-admin.env \
  || { echo "FAIL: purging the obsoleted valkey-admin-server corrupted the live env file"; exit 1; }
echo "ok: dpkg conffile protection kept the live env file intact across the obsoleted purge"

test ! -d /var/lib/valkey-admin \
  || { echo "FAIL: /var/lib/valkey-admin survived the obsoleted purge -- the pre-rename postrm no longer runs its purge branch against it, update this assertion and README.packaging.md together"; exit 1; }
getent passwd valkey-admin >/dev/null \
  && { echo "FAIL: the valkey-admin user survived the obsoleted purge -- the pre-rename postrm no longer runs deluser, update this assertion and README.packaging.md together"; exit 1; }
echo "ok: /var/lib/valkey-admin and the valkey-admin user are NOT protected and were removed by the obsoleted purge, as expected"

dpkg-query -W -f='${Status}' percona-valkey-admin-server 2>/dev/null | grep -q '^install ok installed$' \
  || { echo "FAIL: percona-valkey-admin-server was affected by purging valkey-admin-server"; exit 1; }
echo "ok: percona-valkey-admin-server remains installed after purging the obsoleted name"
SH
echo "ok: deb rename upgrade test passed"
