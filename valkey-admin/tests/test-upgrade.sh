#!/usr/bin/env bash
# Exercises the rename upgrade path: an install of the pre-rename
# valkey-admin-server package, upgraded in place to percona-valkey-admin-server
# through the new package's Provides/Obsoletes. This is the one genuinely new
# piece of packaging behavior in the rename -- everything else is a rename of
# identifiers that were already exercised by the rest of the suite.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
TARGET="el9"
OUT="$PACKAGING_ROOT/out/$TARGET"
# The trailing "|| true" matters under set -euo pipefail: without it, ls
# failing on a no-match glob (exit 2) propagates through the pipe to
# head -1 and, with pipefail, makes this assignment itself exit non-zero --
# which aborts the script right here, silently, before the descriptive
# fail() below ever runs.
NEW_RPM="$(ls "$OUT"/percona-valkey-admin-server-*.rpm 2>/dev/null | head -1 || true)"
[ -n "$NEW_RPM" ] || fail "no percona-valkey-admin-server rpm in out/$TARGET"

# The pre-rename package is built from a small self-contained fixture
# (tests/fixtures/rpm/valkey-admin-fixture.spec), not from an actual
# pre-rename commit in a throwaway git worktree or checkout: no such commit
# exists in this repository at all (this packaging builds from a fetched
# upstream release archive, not an adjacent valkey-admin working tree), and
# even where one might exist it would be local to a single branch and stop
# existing the moment it's squashed, rebased away, or the clone this runs
# from is shallow -- any of which would leave this test permanently red
# through no fault of the change under test. The fixture ships the same
# unbranded paths the real pre-rename package shipped (the unit file, the
# env conffile, /var/lib/valkey-admin) plus a payload marker, which is
# everything this test needs to exercise the file-conflict and
# Provides/Obsoletes resolution -- and it builds in seconds with no npm
# build and no git or network dependency at all.
OLDHOLD="$(mktemp -d)"
CONTAINER="vas-upgrade-test-$$-$RANDOM"
cleanup() {
  rm -rf "$OLDHOLD"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$PACKAGING_ROOT/tests/fixtures/build-fixture-rpm.sh" "$TARGET" "$OLDHOLD" >/dev/null
OLD_RPM="$(ls "$OLDHOLD"/valkey-admin-server-*.rpm 2>/dev/null | head -1 || true)"
[ -n "$OLD_RPM" ] || fail "fixture build produced no valkey-admin-server rpm"
echo "ok: built pre-rename fixture valkey-admin-server rpm"

IMAGE="rockylinux:9"
SYSTEMD_TAG="valkey-admin-pkg:$(printf '%s' "$IMAGE" | tr -c 'a-zA-Z0-9_.-' '-')-systemd-test"

if inst="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null)"; then
  [ "$inst" -ge 256 ] || echo "warning: fs.inotify.max_user_instances=$inst; systemd-in-docker may fail to boot (raise to >=1024)" >&2
fi

# Same systemd-in-docker approach as test-service-runtime.sh: the plain
# rockylinux:9 image has no /sbin/init, and starting the service for real is
# the only way to prove the unit resolves against the NEW payload root after
# the package transition, not just that files landed on disk.
docker build -q -t "$SYSTEMD_TAG" - >/dev/null <<DOCKERFILE
FROM $IMAGE
RUN dnf -y install systemd && dnf clean all
DOCKERFILE

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$OUT:/out:ro" -v "$OLDHOLD:/old:ro" \
  "$SYSTEMD_TAG" /sbin/init >/dev/null

docker exec -i "$CONTAINER" bash -eus <<'SH'
for _ in $(seq 1 60); do
  systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done
systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' || {
  echo "FAIL: systemd never reached running/degraded"; systemctl --failed --no-pager; exit 1; }
dnf -y module reset nodejs >/dev/null 2>&1 || true
dnf -y module enable nodejs:22 >/dev/null 2>&1 || true
dnf -y install --allowerasing nodejs curl >/dev/null

# Install the pre-rename package and act like an operator who has been
# running it for a while: a config edit and data on disk.
dnf -y install /old/valkey-admin-server-*.rpm >/dev/null
rpm -q valkey-admin-server >/dev/null || { echo "FAIL: pre-rename package did not install"; exit 1; }
test -f /usr/lib/valkey-admin-server/marker \
  || { echo "FAIL: pre-rename payload missing before upgrade"; exit 1; }
echo "ok: pre-rename valkey-admin-server installed"

echo "PORT=9999" >> /etc/valkey-admin/valkey-admin.env
echo "operator data" > /var/lib/valkey-admin/operator-marker
echo "ok: operator made a config edit and wrote data before the upgrade"

# The upgrade under test: installing the renamed package over the old one by
# name, relying on Provides/Obsoletes to resolve it as a replacement rather
# than a side-by-side install.
dnf -y install /out/percona-valkey-admin-server-*.rpm >/dev/null

rpm -q valkey-admin-server >/dev/null 2>&1 \
  && { echo "FAIL: valkey-admin-server is still installed after the rename upgrade"; exit 1; }
rpm -q percona-valkey-admin-server >/dev/null \
  || { echo "FAIL: percona-valkey-admin-server is not installed after the rename upgrade"; exit 1; }
echo "ok: Obsoletes replaced valkey-admin-server with percona-valkey-admin-server"

test ! -e /usr/lib/valkey-admin-server \
  || { echo "FAIL: old payload root /usr/lib/valkey-admin-server still present after upgrade"; exit 1; }
test -f /usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs \
  || { echo "FAIL: new payload root /usr/lib/percona-valkey-admin-server missing after upgrade"; exit 1; }
echo "ok: payload root migrated to /usr/lib/percona-valkey-admin-server"

grep -q '^PORT=9999' /etc/valkey-admin/valkey-admin.env \
  || { echo "FAIL: operator edit to valkey-admin.env did not survive the rename upgrade"; exit 1; }
echo "ok: operator edit to valkey-admin.env survived the rename upgrade"

# %config(noreplace) on an identical path shared by both packages can, in
# the wrong circumstances, leave rpm's own conflict-resolution artifacts
# behind alongside the live file -- a stray .rpmsave would silently carry
# forward an old VALKEY_PASSWORD nobody notices sitting on disk. Assert it
# isn't there rather than trusting the noreplace flag alone.
test ! -e /etc/valkey-admin/valkey-admin.env.rpmsave \
  && test ! -e /etc/valkey-admin/valkey-admin.env.rpmnew \
  || { echo "FAIL: stray .rpmsave/.rpmnew next to the live env file after the rename upgrade"; exit 1; }
echo "ok: no stray .rpmsave/.rpmnew next to the live env file"

test -f /var/lib/valkey-admin/operator-marker \
  || { echo "FAIL: /var/lib/valkey-admin contents were lost across the rename upgrade"; exit 1; }
echo "ok: /var/lib/valkey-admin is intact"

# Prove the service actually runs from the new payload root, not just that
# the unit file parses -- the unit name itself is unchanged by the rename.
# Port 9999, not the 8080 default: the preserved PORT=9999 override above is
# only really proven "preserved" if the new payload actually honors it.
systemctl start valkey-admin.service
for i in $(seq 1 30); do
  curl -fsS -o /dev/null http://127.0.0.1:9999/ && break
  sleep 1
done
systemctl is-active --quiet valkey-admin.service || { journalctl -u valkey-admin --no-pager | tail -30; exit 1; }
curl -fsS -o /dev/null -w "ok: GET / -> %{http_code} (served from new payload root, operator PORT override honored)\n" http://127.0.0.1:9999/
systemctl stop valkey-admin.service
echo "ok: service starts from the new payload root after the rename upgrade"

# Removal coverage: the pre-rename test-upgrade.sh asserted that erasing the
# package removed its payload; the rewrite that introduced the rename
# dropped that assertion and nothing else in the suite replaced it. Restore
# it here, against the renamed package, in the same container, after the
# service has been stopped.
dnf -y remove percona-valkey-admin-server >/dev/null
rpm -q percona-valkey-admin-server >/dev/null 2>&1 \
  && { echo "FAIL: percona-valkey-admin-server still reported installed after erase"; exit 1; }
test ! -e /usr/lib/percona-valkey-admin-server \
  || { echo "FAIL: payload root /usr/lib/percona-valkey-admin-server still present after erase"; exit 1; }
echo "ok: erase removed the package and its payload root"
SH
echo "ok: rename upgrade test passed"
