#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/assert.sh"
UNIT="$PACKAGING_ROOT/rpm/valkey-admin.service"
ENVF="$PACKAGING_ROOT/rpm/valkey-admin.env"

assert_file "$UNIT"
assert_file "$PACKAGING_ROOT/rpm/valkey-admin.sysusers"
assert_file "$PACKAGING_ROOT/rpm/valkey-admin.tmpfiles"
assert_file "$ENVF"

grep -qE '^[[:space:]]*MemoryDenyWriteExecute[[:space:]]*=' "$UNIT" \
  && fail "MemoryDenyWriteExecute breaks the V8 JIT"
echo "ok: no MemoryDenyWriteExecute directive"

grep -q '^User=valkey-admin$' "$UNIT" || fail "unit must run as valkey-admin"
echo "ok: runs as valkey-admin"

grep -q '^ReadWritePaths=/var/lib/valkey-admin$' "$UNIT" || fail "DATA_DIR must be writable"
echo "ok: DATA_DIR is writable under ProtectSystem=strict"

grep -qE '^ExecStart=/usr/bin/node /usr/lib/percona-valkey-admin-server/apps/server/dist/index\.cjs$' "$UNIT" \
  || fail "ExecStart must match the installed payload layout"
echo "ok: ExecStart matches payload layout"

grep -q 'SERVER_BIND_HOST' "$ENVF" || fail "config must document SERVER_BIND_HOST"
grep -qE '^[[:space:]]*SERVER_BIND_HOST=' "$ENVF" \
  && fail "SERVER_BIND_HOST must ship commented out so the server defaults to loopback"
echo "ok: SERVER_BIND_HOST documented but not set"
