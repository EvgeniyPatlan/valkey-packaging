#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
TARGET="${TEST_TARGET:-el9}"
OUT="$PACKAGING_ROOT/out/$TARGET"
# The trailing "|| true" matters under set -euo pipefail: without it, ls
# failing on a no-match glob (exit 2) propagates through the pipe to
# head -1 and, with pipefail, makes this assignment itself exit non-zero --
# which aborts the script right here, silently, before the descriptive
# fail() below ever runs.
RPM="$(ls "$OUT"/percona-valkey-admin-server-*.rpm 2>/dev/null | head -1 || true)"
[ -n "$RPM" ] || fail "no percona-valkey-admin-server rpm in out/$TARGET"
IMAGE="${TEST_IMAGE:-rockylinux:9}"
SYSTEMD_TAG="valkey-admin-pkg:$(printf '%s' "$IMAGE" | tr -c 'a-zA-Z0-9_.-' '-')-systemd-test"

if inst="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null)"; then
  [ "$inst" -ge 256 ] || echo "warning: fs.inotify.max_user_instances=$inst; systemd-in-docker may fail to boot (raise to >=1024)" >&2
fi

# The plain rockylinux:9 image ships no systemd / /sbin/init at all, so it
# cannot boot as an init system. Build a small systemd-enabled variant once
# (test infrastructure only, not a shipped packaging artifact) so the runtime
# container boots deterministically.
docker build -q -t "$SYSTEMD_TAG" - >/dev/null <<DOCKERFILE
FROM $IMAGE
RUN dnf -y install systemd && dnf clean all
DOCKERFILE

docker rm -f vas-test >/dev/null 2>&1 || true
docker run -d --name vas-test --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$OUT:/out:ro" \
  "$SYSTEMD_TAG" /sbin/init >/dev/null
trap 'docker rm -f vas-test >/dev/null 2>&1 || true' EXIT

docker exec -i vas-test bash -eus <<'SH'
for _ in $(seq 1 60); do
  systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
  sleep 1
done
systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' || {
  echo "FAIL: systemd never reached running/degraded"; systemctl --failed --no-pager; exit 1; }
dnf -y module reset nodejs >/dev/null 2>&1 || true
dnf -y module enable nodejs:22 >/dev/null 2>&1 || true
# --allowerasing: rockylinux:9 ships curl-minimal, which conflicts with the
# full curl package this test needs for its HTTP checks.
dnf -y install --allowerasing nodejs curl >/dev/null
dnf -y install /out/percona-valkey-admin-server-*.rpm >/dev/null

systemctl start valkey-admin.service
for i in $(seq 1 30); do
  curl -fsS -o /dev/null http://127.0.0.1:8080/ && break
  sleep 1
done
systemctl is-active --quiet valkey-admin.service || { journalctl -u valkey-admin --no-pager | tail -30; exit 1; }
echo "ok: service is active"
curl -fsS -o /dev/null -w "ok: GET / -> %{http_code}\n" http://127.0.0.1:8080/

test "$(systemctl show -p User --value valkey-admin.service)" = "valkey-admin"
echo "ok: runs as valkey-admin"

systemctl stop valkey-admin.service
echo "ok: stops cleanly"
SH
echo "ok: service runtime test passed"
