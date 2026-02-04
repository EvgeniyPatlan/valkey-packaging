#!/bin/sh
set -e

# first arg is `-f` or `--some-option`
# or first arg is `something.conf`
if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
	set -- valkey-server "$@"
fi

# allow the container to be started with `--user`
if [ "$1" = 'valkey-server' -a "$(id -u)" = '0' ]; then
	find . \! -user valkey -exec chown valkey '{}' +
	exec setpriv --reuid=valkey --regid=valkey --clear-groups -- "$0" "$@"
fi

# set an appropriate umask (if one isn't set already)
um="$(umask)"
if [ "$um" = '0022' ]; then
	umask 0077
fi

# Handle environment variable configurations
if [ "$1" = 'valkey-server' ]; then
	# Set password from environment variable if provided
	if [ -n "$VALKEY_PASSWORD" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --requirepass $VALKEY_PASSWORD"
	fi
	
	# Override maxmemory if set
	if [ -n "$VALKEY_MAXMEMORY" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --maxmemory $VALKEY_MAXMEMORY"
	fi
	
	# Override bind address if set
	if [ -n "$VALKEY_BIND" ]; then
		VALKEY_EXTRA_FLAGS="$VALKEY_EXTRA_FLAGS --bind $VALKEY_BIND"
	fi
fi

exec "$@" $VALKEY_EXTRA_FLAGS
