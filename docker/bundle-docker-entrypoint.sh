#!/bin/sh
set -e

# percona-valkey-bundle entrypoint.
#
# Combines the Percona Valkey server image conveniences (VALKEY_PASSWORD /
# VALKEY_MAXMEMORY / VALKEY_BIND, privilege drop) with the upstream
# valkey-bundle behaviour of auto-discovering and loading every installed
# module from the Valkey module directory.

# Valkey module directory: %{_libdir}/valkey/modules on RPM images is
# /usr/lib64/valkey/modules; also check /usr/lib/valkey/modules for safety.
MODULE_DIRS="/usr/lib64/valkey/modules /usr/lib/valkey/modules"
MODULE_ARGS=""

# If a config file is passed, don't double-load modules it already lists.
CONFIG=""
for arg in "$@"; do
	case "$arg" in
		*.conf) CONFIG="$arg" ;;
	esac
done

for dir in $MODULE_DIRS; do
	[ -d "$dir" ] || continue
	for module in "$dir"/*.so; do
		[ -f "$module" ] || continue
		if [ -n "$CONFIG" ] && grep -q "loadmodule[[:space:]]\{1,\}$module" "$CONFIG" 2>/dev/null; then
			continue
		fi
		MODULE_ARGS="$MODULE_ARGS --loadmodule $module"
	done
done

# first arg is `-f` or `--some-option`
# or first arg is `something.conf`
if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
	set -- valkey-server "$@"
fi

# allow the container to be started as root, then drop to the valkey user
if [ "$1" = 'valkey-server' ] && [ "$(id -u)" = '0' ]; then
	find . \! -user valkey -exec chown valkey '{}' +
	exec setpriv --reuid=valkey --regid=valkey --clear-groups -- "$0" "$@"
fi

# set an appropriate umask (if one isn't set already)
um="$(umask)"
if [ "$um" = '0022' ]; then
	umask 0077
fi

if [ "$1" = 'valkey-server' ]; then
	# Environment-variable conveniences (mirror the server image)
	if [ -n "$VALKEY_PASSWORD" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --requirepass $VALKEY_PASSWORD"
	fi
	if [ -n "$VALKEY_MAXMEMORY" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --maxmemory $VALKEY_MAXMEMORY"
	fi
	if [ -n "$VALKEY_BIND" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --bind $VALKEY_BIND"
	fi

	shift
	exec valkey-server "$@" $MODULE_ARGS $VALKEY_EXTRA_FLAGS
fi

# Else, run whatever command was given (e.g. valkey-cli, sh)
exec "$@" $VALKEY_EXTRA_FLAGS
