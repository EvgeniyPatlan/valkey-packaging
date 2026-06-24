# percona-valkey-json

This package installs the Valkey JSON module shared object:

    /usr/lib64/valkey/modules/libjson.so   (RPM)
    /usr/lib/valkey/modules/libjson.so     (DEB)

The module is **not loaded automatically.** Enable it one of two ways:

1. Persistently, in `/etc/valkey/valkey.conf`:

       loadmodule /usr/lib64/valkey/modules/libjson.so   # adjust path on DEB

   then restart the server: `systemctl restart valkey`

2. At runtime, via the CLI:

       valkey-cli MODULE LOAD /usr/lib64/valkey/modules/libjson.so

Verify with `valkey-cli MODULE LIST` (look for `name=json`).

Upstream: https://github.com/valkey-io/valkey-json
