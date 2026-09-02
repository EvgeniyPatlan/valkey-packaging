#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../ansible/roles/valkey-firstboot/files/valkey-firstboot.sh"

setup() {
    export VALKEY_FIRSTBOOT_ROOT="$BATS_TEST_TMPDIR/root"
    export VALKEY_FIRSTBOOT_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export VALKEY_FIRSTBOOT_MODULE_DIR="$BATS_TEST_TMPDIR/modules"
    export VALKEY_FIRSTBOOT_CONSOLE="$BATS_TEST_TMPDIR/console"
    export VALKEY_FIRSTBOOT_SKIP_CHOWN=1
    mkdir -p "$VALKEY_FIRSTBOOT_ROOT/etc/valkey" "$VALKEY_FIRSTBOOT_MODULE_DIR"
    printf 'MemTotal:       16384000 kB\n' > "$VALKEY_FIRSTBOOT_MEMINFO"
    GENERATED="$VALKEY_FIRSTBOOT_ROOT/etc/valkey/valkey-generated.conf"
    MARKER="$VALKEY_FIRSTBOOT_ROOT/etc/valkey/.firstboot-done"
    MOTD="$VALKEY_FIRSTBOOT_ROOT/etc/motd.d/30-valkey"
}

@test 'generates a 32 character alphanumeric password' {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    password=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    [ "${#password}" -eq 32 ]
    [[ "$password" =~ ^[A-Za-z0-9]+$ ]]
}

@test 'generates a different password on a clean run' {
    run "$SCRIPT"
    first=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    rm -rf "$VALKEY_FIRSTBOOT_ROOT/etc/valkey"
    mkdir -p "$VALKEY_FIRSTBOOT_ROOT/etc/valkey"
    run "$SCRIPT"
    second=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    [ "$first" != "$second" ]
}

@test 'sets maxmemory to 70 percent of MemTotal' {
    run "$SCRIPT"
    # 16384000 kB * 1024 * 70 / 100
    [ "$(grep '^maxmemory ' "$GENERATED" | cut -d' ' -f2)" -eq 11744051200 ]
}

@test 'sets the eviction policy to noeviction' {
    run "$SCRIPT"
    grep -qx 'maxmemory-policy noeviction' "$GENERATED"
}

@test 'writes no loadmodule lines for the slim variant' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR/libjson.so"
    export VALKEY_VARIANT=slim
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^requirepass ' "$GENERATED"
    ! grep -q '^loadmodule ' "$GENERATED"
}

@test 'writes one loadmodule line per module for the bundle variant' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR"/{libjson.so,libvalkey_bloom.so,libsearch.so}
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$(grep -c '^loadmodule ' "$GENERATED")" -eq 3 ]
    grep -q "^loadmodule $VALKEY_FIRSTBOOT_MODULE_DIR/libjson.so$" "$GENERATED"
}

@test 'ignores non-module files in the module directory' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR"/{libjson.so,README.txt}
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$(grep -c '^loadmodule ' "$GENERATED")" -eq 1 ]
}

@test 'tolerates a missing module directory' {
    rmdir "$VALKEY_FIRSTBOOT_MODULE_DIR"
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test 'creates the completion marker' {
    run "$SCRIPT"
    [ -e "$MARKER" ]
}

@test 'is a no-op when the marker exists' {
    run "$SCRIPT"
    first=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)" = "$first" ]
}

@test 'writes the password to the console and the motd' {
    run "$SCRIPT"
    password=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    grep -q "$password" "$VALKEY_FIRSTBOOT_CONSOLE"
    grep -q "$password" "$MOTD"
}

@test 'restricts the generated configuration to mode 0640' {
    run "$SCRIPT"
    [ "$(stat -c '%a' "$GENERATED")" = "640" ]
}
