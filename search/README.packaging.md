# percona-valkey-search

This package installs the Valkey Search (vector / full-text search) module:

    /usr/lib64/valkey/modules/libsearch.so   (RPM)
    /usr/lib/valkey/modules/libsearch.so     (DEB)

The module is **not loaded automatically.** Enable it one of two ways:

1. Persistently, in `/etc/valkey/valkey.conf`:

       loadmodule /usr/lib64/valkey/modules/libsearch.so   # adjust path on DEB

   then restart the server: `systemctl restart valkey`

2. At runtime, via the CLI:

       valkey-cli MODULE LOAD /usr/lib64/valkey/modules/libsearch.so

Verify with `valkey-cli MODULE LIST` (look for `name=search`), then try
`FT._LIST` / `FT.CREATE` / `FT.SEARCH` (see the upstream COMMANDS.md).

Upstream: https://github.com/valkey-io/valkey-search
