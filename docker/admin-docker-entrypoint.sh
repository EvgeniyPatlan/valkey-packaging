#!/bin/sh
set -e

# Container defaults. The package deliberately binds loopback and reads its
# configuration from /etc/valkey-admin/valkey-admin.env under systemd; neither
# applies here, so the knobs that a container must own are defaulted in the
# environment instead and every one of them stays overridable with -e.
: "${DEPLOYMENT_MODE:=Web}"
: "${PORT:=8080}"
: "${DATA_DIR:=/var/lib/valkey-admin}"

# Published ports are unreachable unless the server binds the container's
# external interface. This is the explicit opt-in the package will not make for
# a host install. Web mode has no authentication beyond a session cookie, so an
# exposed port must sit behind an authenticating proxy.
: "${SERVER_BIND_HOST:=0.0.0.0}"

# The collector reads CONFIG_PATH at startup and exits if the file is missing,
# so this has to name a file that exists. The packaged default lives under
# /usr, which is not writable here, meaning collector-config edits made in the
# UI would be silently lost; point at the data volume instead and seed it from
# the packaged copy on first start so those edits persist across restarts.
#
# If the volume cannot be written (read-only mount), fall back to the packaged
# file: the collectors then run with the shipped defaults, exactly as they do
# on a host install, rather than failing to start at all.
PACKAGED_CONFIG=/usr/lib/percona-valkey-admin-server/apps/metrics/config.yml
: "${CONFIG_PATH:=${DATA_DIR}/metrics-config.yml}"

if [ ! -e "${CONFIG_PATH}" ] && [ -r "${PACKAGED_CONFIG}" ]; then
    if ! cp "${PACKAGED_CONFIG}" "${CONFIG_PATH}" 2>/dev/null; then
        echo "valkey-admin: ${CONFIG_PATH} is not writable, using ${PACKAGED_CONFIG}" >&2
        CONFIG_PATH="${PACKAGED_CONFIG}"
    fi
fi

export DEPLOYMENT_MODE PORT DATA_DIR SERVER_BIND_HOST CONFIG_PATH

APP=/usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs

# No arguments, or only flags, means "run the server"; anything else is run
# verbatim so the image stays usable for one-off commands.
if [ "$#" -eq 0 ]; then
    set -- node "$APP"
elif [ "${1#-}" != "$1" ]; then
    set -- node "$APP" "$@"
fi

exec "$@"
