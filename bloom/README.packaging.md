# percona-valkey-bloom

This package installs the Valkey Bloom filter module shared object:

    /usr/lib64/valkey/modules/libvalkey_bloom.so   (RPM)
    /usr/lib/valkey/modules/libvalkey_bloom.so     (DEB)

The module is **not loaded automatically.** Enable it one of two ways:

1. Persistently, in `/etc/valkey/valkey.conf`:

       loadmodule /usr/lib64/valkey/modules/libvalkey_bloom.so   # adjust path on DEB

   then restart the server: `systemctl restart valkey`

2. At runtime, via the CLI:

       valkey-cli MODULE LOAD /usr/lib64/valkey/modules/libvalkey_bloom.so

Verify with `valkey-cli MODULE LIST` (look for `name=bf`), then try
`BF.ADD k x` / `BF.EXISTS k x`.

Upstream: https://github.com/valkey-io/valkey-bloom
