#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
IMAGE="${TEST_IMAGE:-debian:12}"
TARGET="${TEST_TARGET:-debian12}"
OUT="$PACKAGING_ROOT/out/$TARGET"
# The trailing "|| true" matters under set -euo pipefail: without it, ls
# failing on a no-match glob (exit 2) propagates through the pipe to
# head -1 and, with pipefail, makes this assignment itself exit non-zero --
# which aborts the script right here, silently, before the descriptive
# fail() below ever runs.
DEB="$(ls "$OUT"/percona-valkey-admin-server_*.deb 2>/dev/null | head -1 || true)"
[ -n "$DEB" ] || fail "no percona-valkey-admin-server deb in out/$TARGET"

docker run --rm -i -v "$OUT:/out:ro" -v "$HERE/../lib/assert.sh:/assert.sh:ro" "$IMAGE" bash -eus <<'SH'
. /assert.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl systemd >/dev/null
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
apt-get install -y --no-install-recommends nodejs >/dev/null
apt-get install -y /out/percona-valkey-admin-server_*.deb

test -f /usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs
test -f /usr/lib/percona-valkey-admin-server/apps/frontend/dist/index.html
test -f /etc/valkey-admin/valkey-admin.env
test -f /lib/systemd/system/valkey-admin.service
id valkey-admin >/dev/null
echo "ok: files and user present"

# postinst repairs these modes after dh_fixperms normalized them at build
# time (see debian/rules and percona-valkey-admin-server.postinst). Assert
# the repair actually landed instead of trusting the scriptlet ran -- the
# same ownership and permissions the RPM carries directly in package
# metadata (rpm/percona-valkey-admin.spec's %files, asserted by
# test-rpm-install.sh) on the file that holds VALKEY_PASSWORD.
assert_mode /etc/valkey-admin/valkey-admin.env 640
assert_owner /etc/valkey-admin/valkey-admin.env root:valkey-admin
assert_mode /etc/valkey-admin 750
assert_owner /etc/valkey-admin root:valkey-admin
assert_mode /var/lib/valkey-admin 750
assert_owner /var/lib/valkey-admin valkey-admin:valkey-admin

node -e 'require("/usr/lib/percona-valkey-admin-server/node_modules/@valkey/valkey-glide")'
echo "ok: valkey-glide native addon loads"

dpkg-deb -f /out/percona-valkey-admin-server_*.deb Depends | grep -qE 'nodejs \(>= 20\)' \
  || { echo "FAIL: package must depend on nodejs (>= 20)"; exit 1; }
echo "ok: depends on nodejs (>= 20)"

dpkg-query -W -f='${Conffiles}' percona-valkey-admin-server | grep -q '/etc/valkey-admin/valkey-admin.env' \
  || { echo "FAIL: env file must be registered as a conffile"; exit 1; }
echo "ok: env file is a conffile"

# Removal coverage: nothing in the suite exercised package removal at all,
# including the purge branch in percona-valkey-admin-server.postrm, which
# deletes operator data (rm -rf /var/lib/valkey-admin) and the service
# account (deluser). Prove that code path actually runs and does what it
# claims, in the same container the package was just installed into.
apt-get purge -y percona-valkey-admin-server >/dev/null
test ! -d /var/lib/valkey-admin \
  || { echo "FAIL: /var/lib/valkey-admin still present after purge"; exit 1; }
getent passwd valkey-admin >/dev/null \
  && { echo "FAIL: valkey-admin system user still present after purge"; exit 1; }
echo "ok: purge removed operator data and the service user (postrm purge branch)"
SH
echo "ok: deb install test passed"
