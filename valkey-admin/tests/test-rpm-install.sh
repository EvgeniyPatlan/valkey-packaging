#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
IMAGE="${TEST_IMAGE:-rockylinux:9}"
TARGET="${TEST_TARGET:-el9}"
OUT="$PACKAGING_ROOT/out/$TARGET"
# The trailing "|| true" matters under set -euo pipefail: without it, ls
# failing on a no-match glob (exit 2) propagates through the pipe to
# head -1 and, with pipefail, makes this assignment itself exit non-zero --
# which aborts the script right here, silently, before the descriptive
# fail() below ever runs.
RPM="$(ls "$OUT"/percona-valkey-admin-server-*.rpm 2>/dev/null | head -1 || true)"
[ -n "$RPM" ] || fail "no percona-valkey-admin-server rpm in out/$TARGET"

docker run --rm -i -v "$OUT:/out:ro" "$IMAGE" bash -eus <<'SH'
dnf -y module reset nodejs >/dev/null 2>&1 || true
dnf -y module enable nodejs:22 >/dev/null 2>&1 || true
# Amazon Linux 2023 has no "nodejs" module stream and its bare "nodejs"
# capability is provided only by node 18, so try the versioned nodejs22
# package first; distros without it (everything else in the matrix) fall
# through to the plain "nodejs" package, already node >= 20 there.
dnf -y install nodejs22 >/dev/null 2>&1 || dnf -y install nodejs >/dev/null
# Both branches above swallow their own failures (module enable is
# best-effort, the nodejs22 attempt falls through to nodejs). Assert the
# environment actually landed on a usable node instead of trusting that it
# did -- this is what makes the floor guaranteed rather than incidental.
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || { echo "FAIL: installed node major is $NODE_MAJOR, need >= 20"; exit 1; }
echo "ok: installed node is >= 20 (major $NODE_MAJOR)"
dnf -y install /out/percona-valkey-admin-server-*.rpm

test -f /usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs
test -f /usr/lib/percona-valkey-admin-server/apps/frontend/dist/index.html
test -f /usr/lib/percona-valkey-admin-server/apps/metrics/dist/index.cjs
test -f /usr/lib/percona-valkey-admin-server/apps/metrics/config.yml
test -f /etc/valkey-admin/valkey-admin.env
test -f /usr/lib/systemd/system/valkey-admin.service
id valkey-admin >/dev/null
test -d /var/lib/valkey-admin
echo "ok: files, user and directory present"

test "$(stat -c %U /var/lib/valkey-admin)" = "valkey-admin"
test "$(stat -c %G /etc/valkey-admin/valkey-admin.env)" = "valkey-admin"
echo "ok: %pre ran — ownership applied at unpack time"

node -e 'require("/usr/lib/percona-valkey-admin-server/node_modules/@valkey/valkey-glide")'
echo "ok: valkey-glide native addon loads"

systemd-analyze verify /usr/lib/systemd/system/valkey-admin.service
echo "ok: systemd unit verifies"

# Epoch-qualified: every EL/Fedora/Amazon nodejs package carries Epoch 1,
# and an unqualified "nodejs >= 20" is satisfied by ANY epoch-1 nodejs
# regardless of its actual version (epoch dominates the comparison
# entirely) -- including node 18. Assert the epoch-pinned form actually
# shipped, not the hollow one.
rpm -q --requires percona-valkey-admin-server | grep -qE 'nodejs >= 1:20' \
  || { echo "FAIL: package must require nodejs >= 1:20 (epoch-pinned)"; exit 1; }
echo "ok: requires nodejs >= 1:20"
SH
echo "ok: rpm install test passed"
