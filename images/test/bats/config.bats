#!/usr/bin/env bats

CONF=/etc/valkey/default.conf
GENERATED=/etc/valkey/valkey-generated.conf

@test 'valkey binds to loopback only' {
    grep -qx 'bind 127.0.0.1 -::1' "$CONF"
}

@test 'protected mode is enabled' {
    grep -qx 'protected-mode yes' "$CONF"
}

@test 'the generated configuration is included as the last directive' {
    [ "$(grep -v '^\s*$' "$CONF" | tail -1)" = "include ${GENERATED}" ]
}

@test 'the generated configuration exists and is empty at bake time' {
    [ -f "$GENERATED" ]
    [ ! -s "$GENERATED" ]
}

@test 'the generated configuration is owned root:valkey with mode 0640' {
    [ "$(stat -c '%U:%G' "$GENERATED")" = "root:valkey" ]
    [ "$(stat -c '%a' "$GENERATED")" = "640" ]
}

@test 'the first-boot script is installed and executable' {
    [ -x /usr/local/sbin/valkey-firstboot ]
}

@test 'the first-boot unit is enabled' {
    systemctl is-enabled valkey-firstboot.service
}

@test 'the first-boot unit carries the correct variant' {
    grep -qx "Environment=VALKEY_VARIANT=${VALKEY_VARIANT:-slim}" \
        /etc/systemd/system/valkey-firstboot.service
}

@test 'the first-boot marker is absent' {
    [ ! -e /etc/valkey/.firstboot-done ]
}

@test 'the sysctl tuning is in place' {
    grep -qx 'vm.overcommit_memory = 1' /etc/sysctl.d/99-valkey.conf
    grep -qx 'net.core.somaxconn = 1024' /etc/sysctl.d/99-valkey.conf
}

@test 'the transparent huge pages unit is enabled' {
    systemctl is-enabled valkey-thp.service
}

@test 'the file descriptor limit drop-in is in place' {
    grep -qx 'LimitNOFILE=65535' /etc/systemd/system/valkey@.service.d/10-limits.conf
}
