#!/usr/bin/env bash
# test_packages.sh — Automated test suite for Percona Valkey packages
#
# Usage: bash scripts/test_packages.sh [--pkg-dir=DIR | --repo] [--version=X.Y.Z]
#
# Auto-detects OS (Debian vs RHEL), installs packages from a local directory
# or from the Percona repository, runs validation tests, removes packages,
# and verifies clean removal.

set -euo pipefail

###############################################################################
# Constants & globals
###############################################################################
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
PKG_DIR=""
INSTALL_MODE=""  # "pkg-dir" or "repo"
REPO_CHANNEL="testing"
OS_FAMILY=""  # "deb" or "rpm"
EXPECTED_VERSION=""
START_TIME=""
FAILED_TESTS=()
SKIPPED_TESTS=()
INSTALLED_PKGS=()

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    RESET=''
fi

###############################################################################
# Utility functions
###############################################################################
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$1")
    printf "  ${RED}FAIL${RESET} %s\n" "$1"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$1")
    printf "  ${YELLOW}SKIP${RESET} %s\n" "$1"
}

section_header() {
    printf "\n${CYAN}${BOLD}=== %s ===${RESET}\n" "$1"
}

###############################################################################
# Assertion helpers
###############################################################################
assert_file_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_file_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -e "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_dir_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_dir_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -d "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_executable() {
    local path="$1" label="${2:-$1}"
    if [[ -x "$path" ]]; then
        pass "$label is executable"
    else
        fail "$label is executable (not executable or missing: $path)"
    fi
}

assert_symlink() {
    local path="$1" label="${2:-$1}"
    if [[ -L "$path" ]]; then
        pass "$label is a symlink"
    elif [[ -f "$path" ]]; then
        # Some packaging may install actual files instead of symlinks
        pass "$label exists (regular file, not symlink)"
    else
        fail "$label is a symlink (not found: $path)"
    fi
}

assert_owner() {
    local path="$1" expected_owner="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label owner is $expected_owner (path not found: $path)"
        return
    fi
    local actual_owner
    actual_owner="$(stat -c '%U:%G' "$path")"
    if [[ "$actual_owner" == "$expected_owner" ]]; then
        pass "$label owner is $expected_owner"
    else
        fail "$label owner is $expected_owner (got: $actual_owner)"
    fi
}

assert_perms() {
    local path="$1" expected_mode="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label mode is $expected_mode (path not found: $path)"
        return
    fi
    local actual_mode
    actual_mode="$(stat -c '%a' "$path")"
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        pass "$label mode is $expected_mode"
    else
        fail "$label mode is $expected_mode (got: $actual_mode)"
    fi
}

assert_command_succeeds() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (command failed: $*)"
    fi
}

assert_command_output_contains() {
    local label="$1" expected="$2"
    shift 2
    local output
    output="$("$@" 2>&1)" || true
    if [[ "$output" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label (expected output containing '$expected', got: '$output')"
    fi
}

assert_systemd_property() {
    local service="$1" property="$2" expected="$3" label="${4:-}"
    [[ -z "$label" ]] && label="$service $property=$expected"
    local actual
    actual="$(systemctl show "$service" --property="$property" --value 2>/dev/null)" || true
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label (got: $actual)"
    fi
}

###############################################################################
# Systemd helpers
###############################################################################
has_systemd() {
    # Check if systemd is PID 1
    [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

wait_for_service() {
    local service_name="$1" timeout="${2:-15}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

###############################################################################
# Operational test infrastructure
###############################################################################
# Ports reserved for operational tests (above 7300 to avoid conflicts)
PORT_REPL_PRIMARY=7379
PORT_REPL_REPLICA1=7380
PORT_REPL_REPLICA2=7381
PORT_SENT_PRIMARY=7382
PORT_SENT_REPLICA=7383
PORT_SENTINEL=26382
PORT_CLUSTER_BASE=7384   # uses 7384-7389 (6 nodes)
PORT_TLS_PLAIN=7391      # plain companion port for TLS server startup check
PORT_TLS=7390
PORT_ACL=7392
PORT_PERSIST_RDB=7393
PORT_PERSIST_AOF=7394
PORT_CFG_RELOAD=7395
PORT_MULTI1=7396
PORT_MULTI2=7397
PORT_PUBSUB=7398
PORT_STREAMS=7399
PORT_TXN=7400
PORT_LUA=7401
PORT_KEYSPACE=7402
PORT_UNIX_TCP=7403       # companion TCP port for unix socket server
PORT_EVICTION=7404
PORT_SLOWLOG=7405
PORT_PERF=7406
PORT_MODULE=7407

TEST_TMP_DIR=""
LAST_TEST_PID=""

setup_operational_tests() {
    TEST_TMP_DIR="$(mktemp -d /tmp/valkey-optest-XXXXXX)"
    printf "\n  ${CYAN}Operational test temp dir:${RESET} %s\n" "$TEST_TMP_DIR"
}

cleanup_operational_tests() {
    if [[ -n "$TEST_TMP_DIR" ]] && [[ -d "$TEST_TMP_DIR" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

# start_test_server <name> <port> [extra valkey-server args...]
# Starts a daemonized valkey-server in $TEST_TMP_DIR/<name>/.
# Sets LAST_TEST_PID to the server PID.  Returns 1 if startup times out.
start_test_server() {
    local name="$1" port="$2"
    shift 2
    local dir="$TEST_TMP_DIR/$name"
    mkdir -p "$dir"
    valkey-server \
        --port "$port" \
        --daemonize yes \
        --logfile "$dir/valkey.log" \
        --dir "$dir" \
        --pidfile "$dir/valkey.pid" \
        --loglevel warning \
        "$@" >/dev/null 2>&1 || true

    local i=0
    while [[ $i -lt 40 ]]; do
        if valkey-cli -p "$port" PING >/dev/null 2>&1; then
            LAST_TEST_PID="$(cat "$dir/valkey.pid" 2>/dev/null || true)"
            return 0
        fi
        sleep 0.25
        i=$((i + 1))
    done
    echo "  WARNING: server '$name' on port $port did not respond within 10s" >&2
    cat "$dir/valkey.log" 2>/dev/null | tail -5 >&2 || true
    return 1
}

# stop_test_server <name> <port>
stop_test_server() {
    local name="$1" port="$2"
    valkey-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    sleep 0.3
    local pid_file="$TEST_TMP_DIR/$name/valkey.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    fi
}

# vcli <port> [args...]  — shorthand valkey-cli wrapper
vcli() {
    local port="$1"; shift
    valkey-cli -p "$port" "$@" 2>&1
}

# info_field <port> <field>  — extract a single field from INFO all
info_field() {
    local port="$1" field="$2"
    valkey-cli -p "$port" INFO all 2>/dev/null \
        | grep -i "^${field}:" | head -1 | cut -d: -f2 | tr -d '[:space:]'
}

# wait_for_replication_link <replica_port> [timeout_seconds]
# Poll the replica's master_link_status until it is "up" or the timeout expires.
# Returns 0 on success, 1 on timeout. Default timeout is 15s because a full
# sync on a loaded container host can take several seconds even with an empty
# dataset — a flat "sleep 1" is not reliable.
wait_for_replication_link() {
    local port="$1" timeout="${2:-15}"
    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        local status
        status="$(info_field "$port" "master_link_status")"
        if [[ "$status" == "up" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

###############################################################################
# OS detection
###############################################################################
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_FAMILY="deb"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || [[ -f /etc/rocky-release ]] || [[ -f /etc/almalinux-release ]]; then
        OS_FAMILY="rpm"
    elif command -v rpm &>/dev/null && command -v yum &>/dev/null; then
        OS_FAMILY="rpm"
    elif command -v dpkg &>/dev/null && command -v apt-get &>/dev/null; then
        OS_FAMILY="deb"
    else
        echo "ERROR: Cannot detect OS family (neither Debian nor RHEL based)" >&2
        exit 1
    fi
    echo "Detected OS family: $OS_FAMILY"
}

###############################################################################
# Package install/remove
###############################################################################
install_packages_deb() {
    section_header "Installing .deb packages"
    # Fix any broken deps first
    apt-get update -qq
    apt-get install -f -y -qq

    local debs=()
    for f in "$PKG_DIR"/percona-valkey*.deb; do
        [[ -f "$f" ]] || continue
        debs+=("$f")
    done

    if [[ ${#debs[@]} -eq 0 ]]; then
        echo "ERROR: No percona-valkey*.deb files found in $PKG_DIR" >&2
        exit 1
    fi

    echo "Installing ${#debs[@]} package(s)..."
    apt-get install -y "${debs[@]}" 2>&1 || {
        echo "Install failed, attempting with --fix-broken..."
        apt-get install -y --fix-broken "${debs[@]}" 2>&1
    }
    # Capture installed package names and versions
    while IFS= read -r line; do
        INSTALLED_PKGS+=("$line")
    done < <(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {printf "%s %s %s\n", $2, $3, $4}')
    echo "Installation complete."
}

install_packages_rpm() {
    section_header "Installing .rpm packages"

    local rpms=()
    for f in "$PKG_DIR"/percona-valkey*.rpm; do
        [[ -f "$f" ]] || continue
        # Skip source RPMs and debuginfo
        [[ "$f" == *.src.rpm ]] && continue
        [[ "$f" == *debuginfo* ]] && continue
        [[ "$f" == *debugsource* ]] && continue
        rpms+=("$f")
    done

    if [[ ${#rpms[@]} -eq 0 ]]; then
        echo "ERROR: No percona-valkey*.rpm files found in $PKG_DIR" >&2
        exit 1
    fi

    echo "Installing ${#rpms[@]} package(s)..."
    yum localinstall -y "${rpms[@]}" 2>&1
    # Capture installed package names and versions
    while IFS= read -r line; do
        [[ -n "$line" ]] && INSTALLED_PKGS+=("$line")
    done < <(rpm -qa 'percona-valkey*' --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' 2>/dev/null)
    echo "Installation complete."
}

###############################################################################
# Repo-based install (percona-release)
###############################################################################
install_percona_release_deb() {
    echo "Installing percona-release (deb)..."
    local tmp_deb
    tmp_deb="$(mktemp /tmp/percona-release-XXXXXX.deb)"
    wget -q -O "$tmp_deb" https://repo.percona.com/apt/percona-release_latest.generic_all.deb
    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    apt-get update -qq
}

install_percona_release_rpm() {
    echo "Installing percona-release (rpm)..."
    yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
}

install_from_repo_deb() {
    section_header "Installing from Percona repo (deb, channel=$REPO_CHANNEL)"
    apt-get update -qq
    apt-get install -y -qq wget gnupg2 lsb-release curl
    apt-get install -y -qq libssl | apt-get install -y -qq libssl3t64
    install_percona_release_deb
    percona-release enable valkey-9.0 "$REPO_CHANNEL"
    apt-get update -qq
    apt-get install -y percona-valkey-server percona-valkey-sentinel \
        percona-valkey-tools percona-valkey-compat-redis percona-valkey-compat-redis-dev \
        percona-valkey-dev
    # Capture installed package names and versions
    while IFS= read -r line; do
        INSTALLED_PKGS+=("$line")
    done < <(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {printf "%s %s %s\n", $2, $3, $4}')
    echo "Installation complete."
}

install_from_repo_rpm() {
    section_header "Installing from Percona repo (rpm, channel=$REPO_CHANNEL)"
    install_percona_release_rpm
    percona-release enable valkey-9.0 "$REPO_CHANNEL"
    yum install -y percona-valkey percona-valkey-compat-redis \
        percona-valkey-compat-redis-devel percona-valkey-devel openssl
    # Capture installed package names and versions
    while IFS= read -r line; do
        [[ -n "$line" ]] && INSTALLED_PKGS+=("$line")
    done < <(rpm -qa 'percona-valkey*' --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' 2>/dev/null)
    echo "Installation complete."
}

remove_packages_deb() {
    section_header "Removing .deb packages"
    # Get list of installed percona-valkey packages
    local pkgs
    pkgs="$(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {print $2}' || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Purging: $pkgs"
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs 2>&1
        apt-get autoremove -y 2>&1
    else
        echo "No percona-valkey packages found to remove."
    fi
    echo "Removal complete."
}

remove_packages_rpm() {
    section_header "Removing .rpm packages"
    local pkgs
    pkgs="$(rpm -qa 'percona-valkey*' 2>/dev/null || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Removing: $pkgs"
        # shellcheck disable=SC2086
        yum remove -y $pkgs 2>&1
    else
        echo "No percona-valkey packages found to remove."
    fi
    echo "Removal complete."
}

###############################################################################
# Tests
###############################################################################
test_binaries() {
    section_header "Test: Binaries"
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_executable "/usr/bin/$bin" "$bin"
    done
    assert_command_succeeds "valkey-server --version" valkey-server --version
    assert_command_succeeds "valkey-cli --version" valkey-cli --version

    # Version checks
    if [[ -n "$EXPECTED_VERSION" ]]; then
        local ver_bins=(valkey-server valkey-cli)
        for bin in "${ver_bins[@]}"; do
            local ver_output
            ver_output="$("$bin" --version 2>&1)" || true
            if [[ "$ver_output" == *"$EXPECTED_VERSION"* ]]; then
                pass "$bin version contains $EXPECTED_VERSION"
            else
                fail "$bin version contains $EXPECTED_VERSION (got: $ver_output)"
            fi
        done
    fi
}

test_user_group() {
    section_header "Test: User & Group"
    if id valkey &>/dev/null; then
        pass "valkey user exists"
    else
        fail "valkey user exists"
    fi

    if getent group valkey &>/dev/null; then
        pass "valkey group exists"
    else
        fail "valkey group exists"
    fi

    local home_dir
    home_dir="$(getent passwd valkey | cut -d: -f6)" || true
    if [[ "$home_dir" == "/var/lib/valkey" ]]; then
        pass "valkey home dir is /var/lib/valkey"
    else
        fail "valkey home dir is /var/lib/valkey (got: $home_dir)"
    fi
}

test_directories() {
    section_header "Test: Directories & Permissions"

    assert_dir_exists /var/lib/valkey
    assert_owner /var/lib/valkey "valkey:valkey"
    assert_perms /var/lib/valkey 750

    assert_dir_exists /var/log/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /var/log/valkey "valkey:adm"
        assert_perms /var/log/valkey 2750
    else
        assert_owner /var/log/valkey "valkey:valkey"
        assert_perms /var/log/valkey 750
    fi

    assert_dir_exists /etc/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /etc/valkey "valkey:valkey"
        assert_perms /etc/valkey 2770
    else
        assert_owner /etc/valkey "root:root"
        assert_perms /etc/valkey 755
    fi
}

test_config_files() {
    section_header "Test: Config Files"

    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_exists /etc/valkey/valkey.conf "valkey.conf"
        assert_owner /etc/valkey/valkey.conf "valkey:valkey" "valkey.conf"
        assert_perms /etc/valkey/valkey.conf 640 "valkey.conf"

        assert_file_exists /etc/valkey/sentinel.conf "sentinel.conf"
        assert_owner /etc/valkey/sentinel.conf "valkey:valkey" "sentinel.conf"
        assert_perms /etc/valkey/sentinel.conf 640 "sentinel.conf"
    else
        assert_file_exists /etc/valkey/default.conf "default.conf"
        assert_owner /etc/valkey/default.conf "root:valkey" "default.conf"
        assert_perms /etc/valkey/default.conf 640 "default.conf"

        assert_file_exists /etc/valkey/sentinel-default.conf "sentinel-default.conf"
        assert_owner /etc/valkey/sentinel-default.conf "root:valkey" "sentinel-default.conf"
        assert_perms /etc/valkey/sentinel-default.conf 660 "sentinel-default.conf"
    fi
}

test_systemd_unit_files() {
    section_header "Test: Systemd Unit Files"

    if ! has_systemd; then
        skip "systemd not available — skipping unit file tests"
        return
    fi

    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_exists /lib/systemd/system/valkey-server.service "valkey-server.service"
        assert_file_exists /lib/systemd/system/valkey-server@.service "valkey-server@.service (templated)"
        assert_file_exists /lib/systemd/system/valkey-sentinel.service "valkey-sentinel.service"
        assert_file_exists /lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service (templated)"
    else
        assert_file_exists /usr/lib/systemd/system/valkey@.service "valkey@.service"
        assert_file_exists /usr/lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service"
        assert_file_exists /usr/lib/systemd/system/valkey.target "valkey.target"
        assert_file_exists /usr/lib/systemd/system/valkey-sentinel.target "valkey-sentinel.target"
        assert_file_exists /usr/lib/tmpfiles.d/valkey.conf "tmpfiles.d/valkey.conf"
        if [[ -f /usr/lib/sysctl.d/00-valkey.conf ]]; then
            pass "sysctl.d/00-valkey.conf exists"
        elif [[ -f /etc/sysctl.d/00-valkey.conf ]]; then
            pass "sysctl.d/00-valkey.conf exists (in /etc)"
        else
            fail "sysctl.d/00-valkey.conf exists (not found in /usr/lib or /etc)"
        fi
    fi
}

test_systemd_service_hardening() {
    section_header "Test: Systemd Service Hardening"

    if ! has_systemd; then
        skip "systemd not available — skipping service hardening tests"
        return
    fi

    local server_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
    else
        server_service="valkey@default"
    fi

    # Detect systemd version for feature-gating
    local sd_ver
    sd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    sd_ver=${sd_ver:-0}

    # Common properties (both deb and rpm)
    local common_props=(
        "Type:notify"
        "User:valkey"
        "Group:valkey"
        "PrivateTmp:yes"
        "ProtectHome:yes"
        "PrivateDevices:yes"
        "ProtectKernelTunables:yes"
        "ProtectKernelModules:yes"
        "ProtectControlGroups:yes"
        "NoNewPrivileges:yes"
        "RestrictNamespaces:yes"
        "RestrictSUIDSGID:yes"
        "RestrictRealtime:yes"
    )

    # ProtectHostname requires systemd >= 242
    if [[ "$sd_ver" -ge 242 ]]; then
        common_props+=("ProtectHostname:yes")
    else
        skip "ProtectHostname (systemd $sd_ver < 242)"
    fi

    # ProtectKernelLogs requires systemd >= 244
    if [[ "$sd_ver" -ge 244 ]]; then
        common_props+=("ProtectKernelLogs:yes")
    else
        skip "ProtectKernelLogs (systemd $sd_ver < 244)"
    fi

    # ProtectClock requires systemd >= 247
    if [[ "$sd_ver" -ge 247 ]]; then
        common_props+=("ProtectClock:yes")
    else
        skip "ProtectClock (systemd $sd_ver < 247)"
    fi

    for entry in "${common_props[@]}"; do
        local prop="${entry%%:*}" expected="${entry#*:}"
        assert_systemd_property "$server_service" "$prop" "$expected"
    done

    # Deb-specific properties
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_systemd_property "$server_service" "ProtectSystem" "strict"
        assert_systemd_property "$server_service" "LimitNOFILE" "65535"
        assert_systemd_property "$server_service" "LimitNOFILESoft" "65535"
        assert_systemd_property "$server_service" "MemoryDenyWriteExecute" "yes"
        assert_systemd_property "$server_service" "PrivateUsers" "yes"
        assert_systemd_property "$server_service" "LockPersonality" "yes"
        assert_systemd_property "$server_service" "Restart" "always"
    fi

    # RPM-specific properties
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_systemd_property "$server_service" "ProtectSystem" "full"
        assert_systemd_property "$server_service" "LimitNOFILE" "10240"
        assert_systemd_property "$server_service" "LimitNOFILESoft" "10240"
        assert_systemd_property "$server_service" "Restart" "on-failure"
    fi
}

test_systemd_enable_disable() {
    section_header "Test: Systemd Enable/Disable"

    if ! has_systemd; then
        skip "systemd not available — skipping enable/disable tests"
        return
    fi

    local server_service sentinel_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        sentinel_service="valkey-sentinel"
    else
        server_service="valkey@default"
        sentinel_service="valkey-sentinel@default"
    fi

    for svc in "$server_service" "$sentinel_service"; do
        # Enable
        if systemctl enable "$svc" >/dev/null 2>&1; then
            pass "systemctl enable $svc"
        else
            fail "systemctl enable $svc"
        fi

        local state
        state="$(systemctl is-enabled "$svc" 2>/dev/null)" || true
        if [[ "$state" == "enabled" ]]; then
            pass "$svc is enabled"
        else
            fail "$svc is enabled (got: $state)"
        fi

        # Disable
        if systemctl disable "$svc" >/dev/null 2>&1; then
            pass "systemctl disable $svc"
        else
            fail "systemctl disable $svc"
        fi

        state="$(systemctl is-enabled "$svc" 2>/dev/null)" || true
        if [[ "$state" == "disabled" ]]; then
            pass "$svc is disabled"
        else
            fail "$svc is disabled (got: $state)"
        fi
    done
}

test_systemd_start_stop_restart() {
    section_header "Test: Systemd Start/Stop/Restart"

    if ! has_systemd; then
        skip "systemd not available — skipping start/stop/restart tests"
        return
    fi

    local server_service sentinel_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        sentinel_service="valkey-sentinel"
    else
        server_service="valkey@default"
        sentinel_service="valkey-sentinel@default"
    fi

    for svc in "$server_service" "$sentinel_service"; do
        # Start
        if systemctl start "$svc" 2>&1; then
            pass "start $svc"
        else
            fail "start $svc"
            journalctl -u "$svc" --no-pager -n 20 2>&1 || true
            continue
        fi

        if wait_for_service "$svc" 15; then
            pass "$svc is active after start"
        else
            fail "$svc is active after start (timed out)"
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        # Get PID before restart
        local pid_before
        pid_before="$(systemctl show "$svc" --property=MainPID --value 2>/dev/null)" || true

        # Restart
        if systemctl restart "$svc" 2>&1; then
            pass "restart $svc"
        else
            fail "restart $svc"
            journalctl -u "$svc" --no-pager -n 20 2>&1 || true
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        if wait_for_service "$svc" 15; then
            pass "$svc is active after restart"
        else
            fail "$svc is active after restart (timed out)"
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        # Verify PID changed
        local pid_after
        pid_after="$(systemctl show "$svc" --property=MainPID --value 2>/dev/null)" || true
        if [[ -n "$pid_after" ]] && [[ "$pid_after" != "0" ]] && [[ "$pid_after" != "$pid_before" ]]; then
            pass "$svc PID changed after restart ($pid_before -> $pid_after)"
        else
            fail "$svc PID changed after restart (before=$pid_before after=$pid_after)"
        fi

        # Stop
        if systemctl stop "$svc" 2>&1; then
            pass "stop $svc"
        else
            fail "stop $svc"
        fi
        sleep 1

        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            pass "$svc is inactive after stop"
        else
            fail "$svc is inactive after stop (still active)"
        fi

        # Stop again — should be idempotent
        if systemctl stop "$svc" 2>&1; then
            pass "stop $svc (idempotent)"
        else
            fail "stop $svc (idempotent)"
        fi
    done
}

test_systemd_runtime_environment() {
    section_header "Test: Systemd Runtime Environment"

    if ! has_systemd; then
        skip "systemd not available — skipping runtime environment tests"
        return
    fi

    local server_service pid_file
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        pid_file="/run/valkey/valkey-server.pid"
    else
        server_service="valkey@default"
        pid_file="/run/valkey/default.pid"
    fi

    echo "Starting $server_service..."
    if ! systemctl start "$server_service" 2>&1; then
        fail "start $server_service for runtime checks"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        return
    fi

    if ! wait_for_service "$server_service" 15; then
        fail "$server_service active for runtime checks (timed out)"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Runtime directory
    assert_dir_exists /run/valkey "/run/valkey"

    # PID file
    if [[ -f "$pid_file" ]]; then
        pass "PID file exists: $pid_file"
    else
        fail "PID file exists: $pid_file"
    fi

    # Journal entries
    local journal_output
    journal_output="$(journalctl -u "$server_service" --no-pager -n 5 2>&1)" || true
    if [[ -n "$journal_output" ]]; then
        pass "journal has entries for $server_service"
    else
        fail "journal has entries for $server_service (empty output)"
    fi

    # Listening port
    if command -v ss &>/dev/null; then
        local ss_output
        ss_output="$(ss -tlnp 2>/dev/null)" || true
        if [[ "$ss_output" == *":6379 "* ]] || [[ "$ss_output" == *":6379"* ]]; then
            pass "listening on port 6379"
        else
            fail "listening on port 6379 (not found in ss output)"
        fi
    else
        skip "ss not available — skipping port check"
    fi

    echo "Stopping $server_service..."
    systemctl stop "$server_service" 2>/dev/null || true
    sleep 1
}

test_systemd_restart_on_failure() {
    section_header "Test: Systemd Restart on Failure"

    if ! has_systemd; then
        skip "systemd not available — skipping restart-on-failure tests"
        return
    fi

    local server_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
    else
        server_service="valkey@default"
    fi

    echo "Starting $server_service..."
    if ! systemctl start "$server_service" 2>&1; then
        fail "start $server_service for restart test"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        return
    fi

    if ! wait_for_service "$server_service" 15; then
        fail "$server_service active for restart test (timed out)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Get original PID
    local old_pid
    old_pid="$(systemctl show "$server_service" --property=MainPID --value 2>/dev/null)" || true
    if [[ -z "$old_pid" ]] || [[ "$old_pid" == "0" ]]; then
        fail "get MainPID for restart test (got: $old_pid)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi
    echo "Original PID: $old_pid"

    # Kill with SEGV to trigger on-failure restart
    echo "Sending SIGSEGV to PID $old_pid..."
    kill -SEGV "$old_pid" 2>/dev/null || true

    # Wait for service to restart
    sleep 2
    if wait_for_service "$server_service" 15; then
        pass "$server_service restarted after SIGSEGV"
    else
        fail "$server_service restarted after SIGSEGV (did not become active)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Verify new PID differs
    local new_pid
    new_pid="$(systemctl show "$server_service" --property=MainPID --value 2>/dev/null)" || true
    if [[ -n "$new_pid" ]] && [[ "$new_pid" != "0" ]] && [[ "$new_pid" != "$old_pid" ]]; then
        pass "new PID ($new_pid) differs from old PID ($old_pid)"
    else
        fail "new PID ($new_pid) differs from old PID ($old_pid)"
    fi

    echo "Stopping $server_service..."
    systemctl stop "$server_service" 2>/dev/null || true
    sleep 1
}

test_systemd_targets() {
    section_header "Test: Systemd Targets (RPM)"

    if [[ "$OS_FAMILY" != "rpm" ]]; then
        skip "not RPM — skipping target tests"
        return
    fi

    if ! has_systemd; then
        skip "systemd not available — skipping target tests"
        return
    fi

    local target_output
    target_output="$(systemctl list-unit-files valkey.target 2>/dev/null)" || true
    if [[ "$target_output" == *"valkey.target"* ]]; then
        pass "valkey.target is loaded"
    else
        fail "valkey.target is loaded (not found in unit files)"
    fi

    target_output="$(systemctl list-unit-files valkey-sentinel.target 2>/dev/null)" || true
    if [[ "$target_output" == *"valkey-sentinel.target"* ]]; then
        pass "valkey-sentinel.target is loaded"
    else
        fail "valkey-sentinel.target is loaded (not found in unit files)"
    fi
}

test_systemd_tmpfiles_sysctl() {
    section_header "Test: Systemd Tmpfiles & Sysctl (RPM)"

    if [[ "$OS_FAMILY" != "rpm" ]]; then
        skip "not RPM — skipping tmpfiles/sysctl tests"
        return
    fi

    # Tmpfiles config
    assert_file_exists /usr/lib/tmpfiles.d/valkey.conf "tmpfiles.d/valkey.conf"

    # Sysctl config
    if [[ -f /usr/lib/sysctl.d/00-valkey.conf ]]; then
        pass "sysctl.d/00-valkey.conf exists"
    elif [[ -f /etc/sysctl.d/00-valkey.conf ]]; then
        pass "sysctl.d/00-valkey.conf exists (in /etc)"
    else
        fail "sysctl.d/00-valkey.conf exists (not found)"
    fi

    # Check sysctl values — these cannot be set inside containers (shared with host)
    local somaxconn
    somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null)" || true
    if [[ -n "$somaxconn" ]] && [[ "$somaxconn" -ge 512 ]]; then
        pass "net.core.somaxconn >= 512 (value: $somaxconn)"
    elif [[ -n "$somaxconn" ]]; then
        skip "net.core.somaxconn not applied (got: $somaxconn, likely container)"
    else
        skip "cannot read net.core.somaxconn"
    fi

    local overcommit
    overcommit="$(sysctl -n vm.overcommit_memory 2>/dev/null)" || true
    if [[ "$overcommit" == "1" ]]; then
        pass "vm.overcommit_memory = 1"
    elif [[ -n "$overcommit" ]]; then
        skip "vm.overcommit_memory not applied (got: $overcommit, likely container)"
    else
        skip "cannot read vm.overcommit_memory"
    fi
}

test_valkey_server_service() {
    section_header "Test: Valkey Server Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-server"
    else
        service_name="valkey@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        echo "--- journalctl output ---"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        echo "---"
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING/PONG test
    local ping_result
    ping_result="$(valkey-cli PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli PING → PONG"
    else
        fail "valkey-cli PING → PONG (got: $ping_result)"
    fi

    # SET/GET functional test
    valkey-cli SET __test_key__ "hello_valkey" >/dev/null 2>&1 || true
    local get_result
    get_result="$(valkey-cli GET __test_key__ 2>&1)" || true
    if [[ "$get_result" == "hello_valkey" ]]; then
        pass "valkey-cli SET/GET functional"
    else
        fail "valkey-cli SET/GET functional (got: $get_result)"
    fi
    valkey-cli DEL __test_key__ >/dev/null 2>&1 || true

    # Process runs as valkey user
    local proc_user
    proc_user="$(ps -o user= -C valkey-server 2>/dev/null | head -1 | tr -d ' ')" || true
    if [[ "$proc_user" == "valkey" ]]; then
        pass "valkey-server runs as valkey user"
    else
        fail "valkey-server runs as valkey user (got: '$proc_user')"
    fi

    # Stop service
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_valkey_sentinel_service() {
    section_header "Test: Valkey Sentinel Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping sentinel service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-sentinel"
    else
        service_name="valkey-sentinel@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING sentinel on port 26379
    local ping_result
    ping_result="$(valkey-cli -p 26379 PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli -p 26379 PING → PONG"
    else
        fail "valkey-cli -p 26379 PING → PONG (got: $ping_result)"
    fi

    # Stop sentinel
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_compat_redis() {
    section_header "Test: Redis Compatibility"

    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_symlink "/usr/bin/$bin" "$bin"
    done

    assert_command_succeeds "redis-cli --version" redis-cli --version

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/libexec/migrate_redis_to_valkey.bash "migrate_redis_to_valkey.bash"
    fi
}

test_dev_headers() {
    section_header "Test: Dev Headers"

    assert_file_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_exists /usr/include/redismodule.h "redismodule.h"

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/lib/rpm/macros.d/macros.valkey "macros.valkey"
    fi
}

test_logrotate() {
    section_header "Test: Logrotate"

    local found=0
    for f in /etc/logrotate.d/*valkey*; do
        if [[ -f "$f" ]]; then
            found=1
            pass "logrotate config exists: $f"
        fi
    done
    if [[ $found -eq 0 ]]; then
        fail "logrotate config exists in /etc/logrotate.d/"
    fi
}

test_clean_removal() {
    section_header "Test: Clean Removal"

    # Binaries should be gone
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Redis compat symlinks should be gone
    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Headers should be gone
    assert_file_not_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_not_exists /usr/include/redismodule.h "redismodule.h"

    # Systemd units should be gone
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_not_exists /lib/systemd/system/valkey-server.service "valkey-server.service"
        assert_file_not_exists /lib/systemd/system/valkey-sentinel.service "valkey-sentinel.service"
    else
        assert_file_not_exists /usr/lib/systemd/system/valkey@.service "valkey@.service"
        assert_file_not_exists /usr/lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service"
    fi

    # Deb purge should remove data/config/log dirs
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_dir_not_exists /var/lib/valkey "/var/lib/valkey"
        assert_dir_not_exists /var/log/valkey "/var/log/valkey"
        assert_dir_not_exists /etc/valkey "/etc/valkey"
    fi
}

###############################################################################
# Operational smoke tests
###############################################################################

# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------
test_op_replication() {
    section_header "Operational Test: Replication"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping replication tests"
        return
    fi

    # Start primary
    if ! start_test_server "repl-primary" "$PORT_REPL_PRIMARY"; then
        fail "replication: start primary on port $PORT_REPL_PRIMARY"
        return
    fi
    pass "replication: primary started on port $PORT_REPL_PRIMARY"

    # Start two replicas
    local replica_started=0
    for port_var in PORT_REPL_REPLICA1 PORT_REPL_REPLICA2; do
        local port="${!port_var}"
        local name="repl-replica-$port"
        if start_test_server "$name" "$port" \
                --replicaof 127.0.0.1 "$PORT_REPL_PRIMARY"; then
            pass "replication: replica started on port $port"
            replica_started=$((replica_started + 1))
        else
            fail "replication: replica started on port $port"
        fi
    done

    if [[ $replica_started -eq 0 ]]; then
        stop_test_server "repl-primary" "$PORT_REPL_PRIMARY"
        return
    fi

    # Poll until the replication link is actually up rather than sleeping a
    # flat second — a full sync handshake on a loaded container host can take
    # multiple seconds even with an empty dataset.
    for port in "$PORT_REPL_REPLICA1" "$PORT_REPL_REPLICA2"; do
        wait_for_replication_link "$port" 15 || true
    done

    # Check primary role
    local role
    role="$(info_field "$PORT_REPL_PRIMARY" "role")"
    if [[ "$role" == "master" ]]; then
        pass "replication: primary reports role:master"
    else
        fail "replication: primary reports role:master (got: $role)"
    fi

    # Check replica roles and link status
    for port in "$PORT_REPL_REPLICA1" "$PORT_REPL_REPLICA2"; do
        local r_role link_status
        r_role="$(info_field "$port" "role")"
        link_status="$(info_field "$port" "master_link_status")"
        if [[ "$r_role" == "slave" ]]; then
            pass "replication: replica $port reports role:slave"
        else
            fail "replication: replica $port reports role:slave (got: $r_role)"
        fi
        if [[ "$link_status" == "up" ]]; then
            pass "replication: replica $port master_link_status:up"
        else
            fail "replication: replica $port master_link_status:up (got: $link_status)"
            # Dump the log tail to help diagnose handshake failures
            local replica_log="$TEST_TMP_DIR/repl-replica-$port/valkey.log"
            if [[ -f "$replica_log" ]]; then
                echo "  --- last 10 lines of $replica_log ---" >&2
                tail -10 "$replica_log" >&2 || true
            fi
        fi
    done

    # Write on primary, poll the replica until it sees the value (handshake
    # may still be in flight even though master_link_status is up for the
    # first replica).
    vcli "$PORT_REPL_PRIMARY" SET __repl_test__ "replicated_value" >/dev/null
    local repl_val="" deadline=$((SECONDS + 10))
    while [[ $SECONDS -lt $deadline ]]; do
        repl_val="$(vcli "$PORT_REPL_REPLICA1" GET __repl_test__)"
        [[ "$repl_val" == "replicated_value" ]] && break
        sleep 0.25
    done
    if [[ "$repl_val" == "replicated_value" ]]; then
        pass "replication: data written on primary readable on replica"
    else
        fail "replication: data written on primary readable on replica (got: $repl_val)"
    fi

    # WAIT — ensure replica is caught up. Give a larger budget than before;
    # with WAIT 1 2000 a slow replica can time out before acknowledging.
    local wait_result
    wait_result="$(vcli "$PORT_REPL_PRIMARY" WAIT 1 5000)"
    if [[ "$wait_result" -ge 1 ]] 2>/dev/null; then
        pass "replication: WAIT confirmed at least 1 replica acknowledged"
    else
        fail "replication: WAIT returned $wait_result (expected >= 1)"
    fi

    # Replica is read-only — writes must be rejected
    local write_err
    write_err="$(vcli "$PORT_REPL_REPLICA1" SET __readonly_test__ "x")"
    if [[ "$write_err" == *"READONLY"* ]]; then
        pass "replication: replica correctly rejects writes (READONLY)"
    else
        fail "replication: replica correctly rejects writes (got: $write_err)"
    fi

    # Promote replica (REPLICAOF NO ONE)
    vcli "$PORT_REPL_REPLICA1" REPLICAOF NO ONE >/dev/null
    sleep 0.5
    local promoted_role
    promoted_role="$(info_field "$PORT_REPL_REPLICA1" "role")"
    if [[ "$promoted_role" == "master" ]]; then
        pass "replication: replica promoted to master via REPLICAOF NO ONE"
    else
        fail "replication: replica promoted to master via REPLICAOF NO ONE (got: $promoted_role)"
    fi

    # Cleanup
    stop_test_server "repl-primary"    "$PORT_REPL_PRIMARY"
    stop_test_server "repl-replica-$PORT_REPL_REPLICA1" "$PORT_REPL_REPLICA1"
    stop_test_server "repl-replica-$PORT_REPL_REPLICA2" "$PORT_REPL_REPLICA2"
}

# ---------------------------------------------------------------------------
# Sentinel Failover
# ---------------------------------------------------------------------------
test_op_sentinel_failover() {
    section_header "Operational Test: Sentinel Failover"

    if ! command -v valkey-server &>/dev/null || ! command -v valkey-sentinel &>/dev/null; then
        skip "valkey-server/sentinel not in PATH — skipping sentinel tests"
        return
    fi

    local primary_port="$PORT_SENT_PRIMARY"
    local replica_port="$PORT_SENT_REPLICA"
    local sentinel_port="$PORT_SENTINEL"
    local sentinel_dir="$TEST_TMP_DIR/sentinel"
    mkdir -p "$sentinel_dir"

    # Start primary
    if ! start_test_server "sent-primary" "$primary_port"; then
        fail "sentinel: start primary"
        return
    fi
    pass "sentinel: primary started on port $primary_port"

    # Start replica
    if ! start_test_server "sent-replica" "$replica_port" \
            --replicaof 127.0.0.1 "$primary_port"; then
        fail "sentinel: start replica"
        stop_test_server "sent-primary" "$primary_port"
        return
    fi
    pass "sentinel: replica started on port $replica_port"

    sleep 1

    # Write a sentinel config
    local sentinel_conf="$sentinel_dir/sentinel.conf"
    cat >"$sentinel_conf" <<EOF
port $sentinel_port
daemonize yes
logfile $sentinel_dir/sentinel.log
pidfile $sentinel_dir/sentinel.pid
dir $sentinel_dir
sentinel monitor mymaster 127.0.0.1 $primary_port 1
sentinel down-after-milliseconds mymaster 3000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
EOF

    valkey-sentinel "$sentinel_conf" >/dev/null 2>&1 || true
    sleep 2

    # Verify sentinel is up
    local s_ping
    s_ping="$(vcli "$sentinel_port" PING)"
    if [[ "$s_ping" == "PONG" ]]; then
        pass "sentinel: sentinel process responded to PING"
    else
        fail "sentinel: sentinel process responded to PING (got: $s_ping)"
        stop_test_server "sent-primary" "$primary_port"
        stop_test_server "sent-replica"  "$replica_port"
        return
    fi

    # Verify sentinel knows the master
    local master_addr
    master_addr="$(valkey-cli -p "$sentinel_port" SENTINEL get-master-addr-by-name mymaster 2>&1 | head -1)"
    if [[ "$master_addr" == "127.0.0.1" ]]; then
        pass "sentinel: sentinel reports master address"
    else
        fail "sentinel: sentinel reports master address (got: $master_addr)"
    fi

    # Kill primary to trigger failover
    echo "  Killing primary to trigger failover..."
    local primary_pid
    primary_pid="$(cat "$TEST_TMP_DIR/sent-primary/valkey.pid" 2>/dev/null || true)"
    [[ -n "$primary_pid" ]] && kill -9 "$primary_pid" 2>/dev/null || true

    # Wait for sentinel to elect a new master (up to 20s)
    local new_master_port="" elapsed=0
    while [[ $elapsed -lt 20 ]]; do
        local addr_line
        addr_line="$(valkey-cli -p "$sentinel_port" SENTINEL get-master-addr-by-name mymaster 2>/dev/null | tail -1 | tr -d '\r')" || true
        if [[ "$addr_line" =~ ^[0-9]+$ ]] && [[ "$addr_line" != "$primary_port" ]]; then
            new_master_port="$addr_line"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ -n "$new_master_port" ]] && [[ "$new_master_port" != "$primary_port" ]]; then
        pass "sentinel: failover elected new master on port $new_master_port"
    else
        fail "sentinel: failover did not elect a new master within 20s"
    fi

    # Verify new master accepts writes. Note: do NOT add `2>&1` to the outer
    # command substitution — vcli already merges stderr into stdout for the
    # valkey-cli call itself, and an outer `2>&1` under `bash -x` will
    # capture the subshell's xtrace output (+ local port=…, + shift, …)
    # into $write_result alongside the reply, turning `OK` into a multi-line
    # blob that fails the == "OK" check.
    if [[ -n "$new_master_port" ]]; then
        local write_result
        write_result="$(vcli "$new_master_port" SET __sentinel_test__ "post_failover")"
        if [[ "$write_result" == "OK" ]]; then
            pass "sentinel: new master accepts writes after failover"
        else
            fail "sentinel: new master accepts writes after failover (got: $write_result)"
        fi
    fi

    # Cleanup sentinel
    local sentinel_pid
    sentinel_pid="$(cat "$sentinel_dir/sentinel.pid" 2>/dev/null || true)"
    [[ -n "$sentinel_pid" ]] && kill "$sentinel_pid" 2>/dev/null || true
    stop_test_server "sent-replica" "$replica_port"
}

# ---------------------------------------------------------------------------
# Cluster Mode
# ---------------------------------------------------------------------------
test_op_cluster() {
    section_header "Operational Test: Cluster Mode"

    if ! command -v valkey-server &>/dev/null || ! command -v valkey-cli &>/dev/null; then
        skip "valkey-server/cli not in PATH — skipping cluster tests"
        return
    fi

    # Check that valkey-cli supports --cluster
    if ! valkey-cli --cluster help >/dev/null 2>&1; then
        skip "valkey-cli --cluster not supported — skipping cluster tests"
        return
    fi

    local base_port="$PORT_CLUSTER_BASE"
    local num_nodes=6  # 3 primary + 3 replica
    local ports=()
    for ((i=0; i<num_nodes; i++)); do
        ports+=($((base_port + i)))
    done

    # Start cluster nodes
    local started=0
    for port in "${ports[@]}"; do
        local name="cluster-$port"
        if start_test_server "$name" "$port" \
                --cluster-enabled yes \
                --cluster-config-file "$TEST_TMP_DIR/cluster-$port/nodes.conf" \
                --cluster-node-timeout 5000 \
                --appendonly no; then
            started=$((started + 1))
        else
            fail "cluster: start node on port $port"
        fi
    done

    if [[ $started -lt $num_nodes ]]; then
        fail "cluster: only $started/$num_nodes nodes started"
        for port in "${ports[@]}"; do
            stop_test_server "cluster-$port" "$port"
        done
        return
    fi
    pass "cluster: all $num_nodes nodes started"

    # Create the cluster
    local host_ports=()
    for port in "${ports[@]}"; do
        host_ports+=("127.0.0.1:$port")
    done

    local create_output
    create_output="$(printf 'yes\n' | valkey-cli --cluster create "${host_ports[@]}" \
        --cluster-replicas 1 2>&1)" || true

    if [[ "$create_output" == *"[OK] All 16384 slots covered"* ]]; then
        pass "cluster: cluster created with all 16384 slots covered"
    else
        fail "cluster: cluster creation (output: $(echo "$create_output" | tail -3))"
        for port in "${ports[@]}"; do
            stop_test_server "cluster-$port" "$port"
        done
        return
    fi

    sleep 1

    # Verify CLUSTER INFO
    local cluster_state
    cluster_state="$(valkey-cli -p "$base_port" CLUSTER INFO 2>/dev/null \
        | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')"
    if [[ "$cluster_state" == "ok" ]]; then
        pass "cluster: CLUSTER INFO reports cluster_state:ok"
    else
        fail "cluster: CLUSTER INFO reports cluster_state:ok (got: $cluster_state)"
    fi

    local slots_assigned
    slots_assigned="$(valkey-cli -p "$base_port" CLUSTER INFO 2>/dev/null \
        | grep '^cluster_slots_assigned:' | cut -d: -f2 | tr -d '[:space:]')"
    if [[ "$slots_assigned" == "16384" ]]; then
        pass "cluster: all 16384 slots assigned"
    else
        fail "cluster: all 16384 slots assigned (got: $slots_assigned)"
    fi

    # Write keys that hash to different slots and read them back
    local write_ok=0 read_ok=0
    for key in "key1" "key2" "key3"; do
        local set_result
        set_result="$(valkey-cli -c -p "$base_port" SET "$key" "val_$key" 2>&1)"
        [[ "$set_result" == "OK" ]] && write_ok=$((write_ok + 1))
    done
    if [[ $write_ok -eq 3 ]]; then
        pass "cluster: wrote 3 keys across cluster slots"
    else
        fail "cluster: wrote 3 keys across cluster slots ($write_ok/3 succeeded)"
    fi

    for key in "key1" "key2" "key3"; do
        local get_result
        get_result="$(valkey-cli -c -p "$base_port" GET "$key" 2>&1)"
        [[ "$get_result" == "val_$key" ]] && read_ok=$((read_ok + 1))
    done
    if [[ $read_ok -eq 3 ]]; then
        pass "cluster: read 3 keys back correctly"
    else
        fail "cluster: read 3 keys back correctly ($read_ok/3 matched)"
    fi

    # Verify CLUSTER NODES topology
    local node_count
    node_count="$(valkey-cli -p "$base_port" CLUSTER NODES 2>/dev/null | wc -l | tr -d '[:space:]')"
    if [[ "$node_count" -eq $num_nodes ]]; then
        pass "cluster: CLUSTER NODES shows $num_nodes nodes"
    else
        fail "cluster: CLUSTER NODES shows $num_nodes nodes (got: $node_count)"
    fi

    # Cleanup
    for port in "${ports[@]}"; do
        stop_test_server "cluster-$port" "$port"
    done
}

# ---------------------------------------------------------------------------
# Persistence (RDB + AOF)
# ---------------------------------------------------------------------------
test_op_persistence() {
    section_header "Operational Test: Persistence"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping persistence tests"
        return
    fi

    # --- RDB ---
    if start_test_server "persist-rdb" "$PORT_PERSIST_RDB" \
            --save "" \
            --dbfilename "dump.rdb"; then
        pass "persistence: RDB server started"
    else
        fail "persistence: RDB server started"
        return
    fi

    vcli "$PORT_PERSIST_RDB" SET __rdb_key__ "rdb_value" >/dev/null
    local bgsave_result
    bgsave_result="$(vcli "$PORT_PERSIST_RDB" BGSAVE)"
    if [[ "$bgsave_result" == *"Background saving started"* ]] || [[ "$bgsave_result" == "OK" ]]; then
        pass "persistence: BGSAVE initiated"
    else
        fail "persistence: BGSAVE initiated (got: $bgsave_result)"
    fi

    # Wait for BGSAVE to complete
    local i=0
    while [[ $i -lt 20 ]]; do
        local bgsave_status
        bgsave_status="$(info_field "$PORT_PERSIST_RDB" "rdb_bgsave_in_progress")"
        [[ "$bgsave_status" == "0" ]] && break
        sleep 0.5
        i=$((i + 1))
    done

    local rdb_file="$TEST_TMP_DIR/persist-rdb/dump.rdb"
    if [[ -f "$rdb_file" ]]; then
        pass "persistence: RDB dump file created"
    else
        fail "persistence: RDB dump file created (not found: $rdb_file)"
    fi

    stop_test_server "persist-rdb" "$PORT_PERSIST_RDB"

    # Restart and verify data loaded
    if start_test_server "persist-rdb" "$PORT_PERSIST_RDB" \
            --save "" \
            --dbfilename "dump.rdb"; then
        local rdb_val
        rdb_val="$(vcli "$PORT_PERSIST_RDB" GET __rdb_key__)"
        if [[ "$rdb_val" == "rdb_value" ]]; then
            pass "persistence: RDB data survives server restart"
        else
            fail "persistence: RDB data survives server restart (got: $rdb_val)"
        fi
    else
        fail "persistence: RDB server restart"
    fi
    stop_test_server "persist-rdb" "$PORT_PERSIST_RDB"

    # --- AOF ---
    if start_test_server "persist-aof" "$PORT_PERSIST_AOF" \
            --appendonly yes \
            --appendfilename "appendonly.aof" \
            --save ""; then
        pass "persistence: AOF server started"
    else
        fail "persistence: AOF server started"
        return
    fi

    vcli "$PORT_PERSIST_AOF" SET __aof_key__ "aof_value" >/dev/null
    vcli "$PORT_PERSIST_AOF" SET __aof_key2__ "aof_value2" >/dev/null

    # Crash-stop (kill -9) to simulate unclean shutdown
    local aof_pid
    aof_pid="$(cat "$TEST_TMP_DIR/persist-aof/valkey.pid" 2>/dev/null || true)"
    [[ -n "$aof_pid" ]] && kill -9 "$aof_pid" 2>/dev/null || true
    sleep 0.5

    # Restart — AOF must recover both keys
    if start_test_server "persist-aof" "$PORT_PERSIST_AOF" \
            --appendonly yes \
            --appendfilename "appendonly.aof" \
            --save ""; then
        local aof_val aof_val2
        aof_val="$(vcli "$PORT_PERSIST_AOF" GET __aof_key__)"
        aof_val2="$(vcli "$PORT_PERSIST_AOF" GET __aof_key2__)"
        if [[ "$aof_val" == "aof_value" ]] && [[ "$aof_val2" == "aof_value2" ]]; then
            pass "persistence: AOF data recovered after crash-stop"
        else
            fail "persistence: AOF data recovered after crash-stop (got: '$aof_val', '$aof_val2')"
        fi
    else
        fail "persistence: AOF server restart after crash"
    fi

    # BGREWRITEAOF
    local rewrite_result
    rewrite_result="$(vcli "$PORT_PERSIST_AOF" BGREWRITEAOF)"
    if [[ "$rewrite_result" == *"started"* ]]; then
        pass "persistence: BGREWRITEAOF initiated"
    else
        fail "persistence: BGREWRITEAOF initiated (got: $rewrite_result)"
    fi

    # Wait for rewrite to finish
    i=0
    while [[ $i -lt 20 ]]; do
        local aof_rewrite_status
        aof_rewrite_status="$(info_field "$PORT_PERSIST_AOF" "aof_rewrite_in_progress")"
        [[ "$aof_rewrite_status" == "0" ]] && break
        sleep 0.5
        i=$((i + 1))
    done

    # Restart again to verify data intact after rewrite
    stop_test_server "persist-aof" "$PORT_PERSIST_AOF"
    if start_test_server "persist-aof" "$PORT_PERSIST_AOF" \
            --appendonly yes \
            --appendfilename "appendonly.aof" \
            --save ""; then
        local post_rewrite_val
        post_rewrite_val="$(vcli "$PORT_PERSIST_AOF" GET __aof_key__)"
        if [[ "$post_rewrite_val" == "aof_value" ]]; then
            pass "persistence: data intact after BGREWRITEAOF + restart"
        else
            fail "persistence: data intact after BGREWRITEAOF + restart (got: $post_rewrite_val)"
        fi
    else
        fail "persistence: server restart after BGREWRITEAOF"
    fi

    # AOF file(s) must exist after the server has restarted and written data.
    # Valkey 7+ uses multi-part AOF by default: an appendonlydir/ subdirectory
    # containing a manifest plus .base.rdb / .incr.aof files. We therefore
    # check both the legacy single-file layout and the new multi-part layout.
    local aof_dir="$TEST_TMP_DIR/persist-aof"
    if [[ -f "$aof_dir/appendonly.aof" ]] \
        || compgen -G "$aof_dir/appendonlydir/*" >/dev/null \
        || compgen -G "$aof_dir/*.aof*" >/dev/null \
        || compgen -G "$aof_dir/*.manifest" >/dev/null; then
        pass "persistence: AOF file(s) present after restart"
    else
        fail "persistence: AOF file(s) present after restart"
        echo "  --- contents of $aof_dir ---" >&2
        ls -la "$aof_dir" >&2 2>/dev/null || true
        [[ -d "$aof_dir/appendonlydir" ]] && ls -la "$aof_dir/appendonlydir" >&2 2>/dev/null || true
    fi

    stop_test_server "persist-aof" "$PORT_PERSIST_AOF"
}

# ---------------------------------------------------------------------------
# ACL
# ---------------------------------------------------------------------------
test_op_acl() {
    section_header "Operational Test: ACL"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping ACL tests"
        return
    fi

    if ! start_test_server "acl" "$PORT_ACL"; then
        fail "ACL: server started"
        return
    fi
    pass "ACL: server started"

    # Create a read-only user
    local acl_add
    acl_add="$(vcli "$PORT_ACL" ACL SETUSER readonly_user on '>readpass' '~*' '+GET' '+PING')"
    if [[ "$acl_add" == "OK" ]]; then
        pass "ACL: read-only user created"
    else
        fail "ACL: read-only user created (got: $acl_add)"
    fi

    # Seed a key as default user
    vcli "$PORT_ACL" SET __acl_key__ "acl_val" >/dev/null

    # Read-only user can GET
    local ro_get
    ro_get="$(valkey-cli -p "$PORT_ACL" -a readpass --user readonly_user GET __acl_key__ 2>&1 | grep -v Warning)"
    if [[ "$ro_get" == "acl_val" ]]; then
        pass "ACL: read-only user can GET"
    else
        fail "ACL: read-only user can GET (got: $ro_get)"
    fi

    # Read-only user cannot SET
    local ro_set
    ro_set="$(valkey-cli -p "$PORT_ACL" -a readpass --user readonly_user SET __acl_key__ "x" 2>&1 | grep -v Warning)"
    if [[ "$ro_set" == *"NOPERM"* ]]; then
        pass "ACL: read-only user correctly blocked from SET (NOPERM)"
    else
        fail "ACL: read-only user correctly blocked from SET (got: $ro_set)"
    fi

    # Key-prefix scoped user (can only access cache:* keys)
    vcli "$PORT_ACL" ACL SETUSER prefix_user on '>prefixpass' '~cache:*' '+SET' '+GET' '+PING' >/dev/null

    local prefix_set
    prefix_set="$(valkey-cli -p "$PORT_ACL" -a prefixpass --user prefix_user SET "cache:item1" "v1" 2>&1 | grep -v Warning)"
    if [[ "$prefix_set" == "OK" ]]; then
        pass "ACL: prefix user can write to allowed key prefix"
    else
        fail "ACL: prefix user can write to allowed key prefix (got: $prefix_set)"
    fi

    local cross_prefix
    cross_prefix="$(valkey-cli -p "$PORT_ACL" -a prefixpass --user prefix_user SET "other:item1" "v1" 2>&1 | grep -v Warning)"
    if [[ "$cross_prefix" == *"NOPERM"* ]]; then
        pass "ACL: prefix user blocked from cross-prefix key access"
    else
        fail "ACL: prefix user blocked from cross-prefix key access (got: $cross_prefix)"
    fi

    # Wrong password rejected
    local bad_auth
    bad_auth="$(valkey-cli -p "$PORT_ACL" -a wrongpass --user readonly_user PING 2>&1 | grep -v Warning)"
    if [[ "$bad_auth" == *"WRONGPASS"* ]] || [[ "$bad_auth" == *"NOAUTH"* ]] || [[ "$bad_auth" == *"invalid"* ]]; then
        pass "ACL: wrong password is rejected"
    else
        fail "ACL: wrong password is rejected (got: $bad_auth)"
    fi

    # ACL LOG should capture denied commands
    # Trigger a denial
    valkey-cli -p "$PORT_ACL" -a readpass --user readonly_user SET __acl_key__ "x" >/dev/null 2>&1 || true
    local acl_log
    acl_log="$(vcli "$PORT_ACL" ACL LOG)"
    if [[ "$acl_log" != "(empty array)" ]] && [[ "$acl_log" != "" ]]; then
        pass "ACL: ACL LOG captured denied command"
    else
        fail "ACL: ACL LOG captured denied command (log empty)"
    fi

    # ACL config survives restart — save to aclfile and restart
    local aclfile="$TEST_TMP_DIR/acl/users.acl"
    vcli "$PORT_ACL" ACL SAVE >/dev/null 2>&1 || true
    # Check via CONFIG SET if aclfile is supported
    vcli "$PORT_ACL" CONFIG SET aclfile "$aclfile" >/dev/null 2>&1 || true
    vcli "$PORT_ACL" ACL SAVE >/dev/null 2>&1 || true

    stop_test_server "acl" "$PORT_ACL"

    if start_test_server "acl" "$PORT_ACL" --aclfile "$aclfile" 2>/dev/null; then
        local acl_list
        acl_list="$(vcli "$PORT_ACL" ACL LIST)"
        if [[ "$acl_list" == *"readonly_user"* ]]; then
            pass "ACL: user config survives service restart (loaded from aclfile)"
        else
            fail "ACL: user config survives service restart (readonly_user not in ACL LIST)"
        fi
        stop_test_server "acl" "$PORT_ACL"
    else
        skip "ACL: aclfile restart test skipped (server failed to start with aclfile)"
    fi
}

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
test_op_tls() {
    section_header "Operational Test: TLS"

    if ! command -v valkey-server &>/dev/null || ! command -v openssl &>/dev/null; then
        skip "valkey-server or openssl not available — skipping TLS tests"
        return
    fi

    # Check that TLS support is compiled in
    if ! valkey-server --tls-port 0 --port 0 --help 2>&1 | grep -q 'tls'; then
        # Try a quick probe
        local tls_check
        tls_check="$(valkey-server --version 2>&1)"
        if [[ "$tls_check" != *"tls"* ]] && ! valkey-cli --tls --help >/dev/null 2>&1; then
            skip "TLS support not compiled in — skipping TLS tests"
            return
        fi
    fi

    local tls_dir="$TEST_TMP_DIR/tls"
    mkdir -p "$tls_dir"

    # Generate self-signed CA + server cert
    openssl genrsa -out "$tls_dir/ca.key" 2048 >/dev/null 2>&1
    openssl req -new -x509 -days 1 -key "$tls_dir/ca.key" \
        -out "$tls_dir/ca.crt" \
        -subj "/CN=TestCA" >/dev/null 2>&1
    openssl genrsa -out "$tls_dir/server.key" 2048 >/dev/null 2>&1
    openssl req -new -key "$tls_dir/server.key" \
        -out "$tls_dir/server.csr" \
        -subj "/CN=127.0.0.1" >/dev/null 2>&1
    openssl x509 -req -days 1 \
        -in "$tls_dir/server.csr" \
        -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial \
        -out "$tls_dir/server.crt" >/dev/null 2>&1

    if [[ ! -f "$tls_dir/server.crt" ]]; then
        fail "TLS: generate self-signed certificates"
        return
    fi
    pass "TLS: self-signed certificates generated"

    # Start TLS server (plain port disabled)
    local tls_server_dir="$TEST_TMP_DIR/tls-server"
    mkdir -p "$tls_server_dir"
    valkey-server \
        --port "$PORT_TLS_PLAIN" \
        --tls-port "$PORT_TLS" \
        --tls-cert-file "$tls_dir/server.crt" \
        --tls-key-file  "$tls_dir/server.key" \
        --tls-ca-cert-file "$tls_dir/ca.crt" \
        --daemonize yes \
        --logfile "$tls_server_dir/valkey.log" \
        --dir "$tls_server_dir" \
        --pidfile "$tls_server_dir/valkey.pid" \
        --loglevel warning >/dev/null 2>&1 || true

    # Wait for plain port (TLS port may not respond to plain PING)
    local i=0
    while [[ $i -lt 40 ]]; do
        valkey-cli -p "$PORT_TLS_PLAIN" PING >/dev/null 2>&1 && break
        sleep 0.25; i=$((i+1))
    done

    # Connect via TLS and PING
    local tls_ping
    tls_ping="$(valkey-cli -p "$PORT_TLS" \
        --tls \
        --cacert "$tls_dir/ca.crt" \
        --cert   "$tls_dir/server.crt" \
        --key    "$tls_dir/server.key" \
        PING 2>&1)" || true

    if [[ "$tls_ping" == "PONG" ]]; then
        pass "TLS: TLS connection PING → PONG"
    else
        fail "TLS: TLS connection PING → PONG (got: $tls_ping)"
    fi

    # Verify plain-text connection to TLS port is rejected
    local plain_result
    plain_result="$(valkey-cli -p "$PORT_TLS" PING 2>&1)" || true
    if [[ "$plain_result" != "PONG" ]]; then
        pass "TLS: plain-text connection to TLS port is rejected"
    else
        fail "TLS: plain-text connection to TLS port is rejected (accepted plain text)"
    fi

    # Cleanup
    valkey-cli -p "$PORT_TLS_PLAIN" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    sleep 0.3
    local tls_pid
    tls_pid="$(cat "$tls_server_dir/valkey.pid" 2>/dev/null || true)"
    [[ -n "$tls_pid" ]] && kill "$tls_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Config Reload / Runtime Config
# ---------------------------------------------------------------------------
test_op_config_reload() {
    section_header "Operational Test: Config Reload / Runtime Config"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping config reload tests"
        return
    fi

    if ! start_test_server "cfg-reload" "$PORT_CFG_RELOAD"; then
        fail "config reload: server started"
        return
    fi
    pass "config reload: server started"

    # CONFIG SET hz
    local set_result
    set_result="$(vcli "$PORT_CFG_RELOAD" CONFIG SET hz 15)"
    if [[ "$set_result" == "OK" ]]; then
        pass "config reload: CONFIG SET hz 15"
    else
        fail "config reload: CONFIG SET hz 15 (got: $set_result)"
    fi

    # CONFIG GET reflects new value
    local get_hz
    get_hz="$(vcli "$PORT_CFG_RELOAD" CONFIG GET hz | tail -1 | tr -d '[:space:]')"
    if [[ "$get_hz" == "15" ]]; then
        pass "config reload: CONFIG GET hz returns 15"
    else
        fail "config reload: CONFIG GET hz returns 15 (got: $get_hz)"
    fi

    # CONFIG SET maxmemory
    set_result="$(vcli "$PORT_CFG_RELOAD" CONFIG SET maxmemory 100mb)"
    if [[ "$set_result" == "OK" ]]; then
        pass "config reload: CONFIG SET maxmemory 100mb"
    else
        fail "config reload: CONFIG SET maxmemory 100mb (got: $set_result)"
    fi

    local get_mem
    get_mem="$(vcli "$PORT_CFG_RELOAD" CONFIG GET maxmemory | tail -1 | tr -d '[:space:]')"
    if [[ "$get_mem" == "104857600" ]]; then
        pass "config reload: CONFIG GET maxmemory returns 104857600"
    else
        fail "config reload: CONFIG GET maxmemory returns 104857600 (got: $get_mem)"
    fi

    # CONFIG REWRITE (needs a config file)
    local cfg_file="$TEST_TMP_DIR/cfg-reload/test.conf"
    echo "hz 10" > "$cfg_file"
    vcli "$PORT_CFG_RELOAD" CONFIG SET save "" >/dev/null  # suppress warning
    set_result="$(vcli "$PORT_CFG_RELOAD" CONFIG REWRITE)" 2>/dev/null || true
    # REWRITE requires the server to have been started with a config file;
    # we didn't, so ERR is expected — just verify it doesn't crash
    if [[ "$set_result" == "OK" ]] || [[ "$set_result" == *"ERR"* ]]; then
        pass "config reload: CONFIG REWRITE returns OK or expected ERR (not a crash)"
    else
        fail "config reload: CONFIG REWRITE (got: $set_result)"
    fi

    # Invalid CONFIG SET must error without crashing
    local invalid_result
    invalid_result="$(vcli "$PORT_CFG_RELOAD" CONFIG SET hz not_a_number)"
    if [[ "$invalid_result" == *"ERR"* ]] || [[ "$invalid_result" == *"Invalid"* ]]; then
        pass "config reload: invalid CONFIG SET returns error without crash"
    else
        fail "config reload: invalid CONFIG SET returns error without crash (got: $invalid_result)"
    fi

    # SIGHUP reload (send SIGHUP and verify server still responds)
    local server_pid
    server_pid="$(cat "$TEST_TMP_DIR/cfg-reload/valkey.pid" 2>/dev/null || true)"
    if [[ -n "$server_pid" ]]; then
        kill -HUP "$server_pid" 2>/dev/null || true
        sleep 0.5
        local ping_after_hup
        ping_after_hup="$(vcli "$PORT_CFG_RELOAD" PING)"
        if [[ "$ping_after_hup" == "PONG" ]]; then
            pass "config reload: server responds after SIGHUP"
        else
            fail "config reload: server responds after SIGHUP (got: $ping_after_hup)"
        fi
    else
        skip "config reload: SIGHUP test skipped (could not read PID)"
    fi

    stop_test_server "cfg-reload" "$PORT_CFG_RELOAD"
}

# ---------------------------------------------------------------------------
# Multi-instance (templated units)
# ---------------------------------------------------------------------------
test_op_multi_instance() {
    section_header "Operational Test: Multi-instance"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping multi-instance tests"
        return
    fi

    local port1="$PORT_MULTI1" port2="$PORT_MULTI2"

    # Start two independent instances
    if ! start_test_server "multi-inst1" "$port1"; then
        fail "multi-instance: instance 1 started on port $port1"
        return
    fi
    pass "multi-instance: instance 1 started on port $port1"

    if ! start_test_server "multi-inst2" "$port2"; then
        fail "multi-instance: instance 2 started on port $port2"
        stop_test_server "multi-inst1" "$port1"
        return
    fi
    pass "multi-instance: instance 2 started on port $port2"

    # Both running concurrently
    local ping1 ping2
    ping1="$(vcli "$port1" PING)"
    ping2="$(vcli "$port2" PING)"
    if [[ "$ping1" == "PONG" ]] && [[ "$ping2" == "PONG" ]]; then
        pass "multi-instance: both instances respond to PING concurrently"
    else
        fail "multi-instance: both instances respond to PING concurrently (got: $ping1, $ping2)"
    fi

    # Each has its own data directory
    local dir1="$TEST_TMP_DIR/multi-inst1" dir2="$TEST_TMP_DIR/multi-inst2"
    assert_dir_exists "$dir1" "multi-instance: instance 1 data dir"
    assert_dir_exists "$dir2" "multi-instance: instance 2 data dir"

    # Data isolation — key set on instance 1 not visible on instance 2
    vcli "$port1" SET __multi_key__ "inst1_val" >/dev/null
    local iso_val
    iso_val="$(vcli "$port2" GET __multi_key__)"
    if [[ "$iso_val" == "" ]] || [[ "$iso_val" == "(nil)" ]]; then
        pass "multi-instance: instances have isolated keyspaces"
    else
        fail "multi-instance: instances have isolated keyspaces (instance 2 returned: $iso_val)"
    fi

    stop_test_server "multi-inst1" "$port1"
    stop_test_server "multi-inst2" "$port2"
}

# ---------------------------------------------------------------------------
# Pub/Sub
# ---------------------------------------------------------------------------
test_op_pubsub() {
    section_header "Operational Test: Pub/Sub"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping Pub/Sub tests"
        return
    fi

    if ! start_test_server "pubsub" "$PORT_PUBSUB"; then
        fail "pubsub: server started"
        return
    fi
    pass "pubsub: server started"

    # Subscribe in background, publish, capture received message
    local sub_out="$TEST_TMP_DIR/pubsub/sub.out"
    timeout 5 valkey-cli -p "$PORT_PUBSUB" SUBSCRIBE testchan >"$sub_out" 2>&1 &
    local sub_pid=$!
    sleep 0.5

    vcli "$PORT_PUBSUB" PUBLISH testchan "hello_pubsub" >/dev/null
    sleep 0.5
    kill "$sub_pid" 2>/dev/null || true
    wait "$sub_pid" 2>/dev/null || true

    if grep -q "hello_pubsub" "$sub_out" 2>/dev/null; then
        pass "pubsub: subscriber received published message"
    else
        fail "pubsub: subscriber received published message (sub output: $(cat "$sub_out" 2>/dev/null | tr '\n' ' '))"
    fi

    stop_test_server "pubsub" "$PORT_PUBSUB"
}

# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------
test_op_streams() {
    section_header "Operational Test: Streams"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping Streams tests"
        return
    fi

    if ! start_test_server "streams" "$PORT_STREAMS"; then
        fail "streams: server started"
        return
    fi
    pass "streams: server started"

    # XADD entries
    local id1 id2
    id1="$(vcli "$PORT_STREAMS" XADD mystream '*' field1 value1)"
    id2="$(vcli "$PORT_STREAMS" XADD mystream '*' field2 value2)"
    if [[ "$id1" =~ ^[0-9]+-[0-9]+$ ]] && [[ "$id2" =~ ^[0-9]+-[0-9]+$ ]]; then
        pass "streams: XADD returned valid entry IDs"
    else
        fail "streams: XADD returned valid entry IDs (got: $id1, $id2)"
    fi

    # XLEN
    local xlen
    xlen="$(vcli "$PORT_STREAMS" XLEN mystream)"
    if [[ "$xlen" == "2" ]]; then
        pass "streams: XLEN reports 2 entries"
    else
        fail "streams: XLEN reports 2 entries (got: $xlen)"
    fi

    # XREAD
    local xread_output
    xread_output="$(vcli "$PORT_STREAMS" XREAD COUNT 2 STREAMS mystream 0)"
    if [[ "$xread_output" == *"value1"* ]] && [[ "$xread_output" == *"value2"* ]]; then
        pass "streams: XREAD returned both entries"
    else
        fail "streams: XREAD returned both entries (got: $xread_output)"
    fi

    # Consumer group
    vcli "$PORT_STREAMS" XGROUP CREATE mystream grp1 0 >/dev/null
    local xreadgroup_output
    xreadgroup_output="$(vcli "$PORT_STREAMS" XREADGROUP GROUP grp1 consumer1 COUNT 10 STREAMS mystream '>')"
    if [[ "$xreadgroup_output" == *"value1"* ]]; then
        pass "streams: XREADGROUP consumer group reads entries"
    else
        fail "streams: XREADGROUP consumer group reads entries (got: $xreadgroup_output)"
    fi

    # XACK
    local xack_result
    xack_result="$(vcli "$PORT_STREAMS" XACK mystream grp1 "$id1")"
    if [[ "$xack_result" == "1" ]]; then
        pass "streams: XACK acknowledged entry"
    else
        fail "streams: XACK acknowledged entry (got: $xack_result)"
    fi

    # XPENDING — one entry still pending
    local xpending_output
    xpending_output="$(vcli "$PORT_STREAMS" XPENDING mystream grp1 - '+' 10)"
    if [[ "$xpending_output" == *"$id2"* ]]; then
        pass "streams: XPENDING shows unacknowledged entry"
    else
        fail "streams: XPENDING shows unacknowledged entry (got: $xpending_output)"
    fi

    stop_test_server "streams" "$PORT_STREAMS"
}

# ---------------------------------------------------------------------------
# Transactions (MULTI/EXEC/WATCH)
# ---------------------------------------------------------------------------
test_op_transactions() {
    section_header "Operational Test: Transactions (MULTI/EXEC/WATCH)"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping transaction tests"
        return
    fi

    if ! start_test_server "txn" "$PORT_TXN"; then
        fail "transactions: server started"
        return
    fi
    pass "transactions: server started"

    # Basic MULTI/EXEC
    local exec_result
    exec_result="$(valkey-cli -p "$PORT_TXN" <<'EOF'
MULTI
SET txn_key hello
INCR txn_counter
EXEC
EOF
)"
    if [[ "$exec_result" == *"OK"* ]] && [[ "$exec_result" == *"1"* ]]; then
        pass "transactions: MULTI/EXEC executes queued commands"
    else
        fail "transactions: MULTI/EXEC executes queued commands (got: $exec_result)"
    fi

    # DISCARD
    local discard_result
    discard_result="$(valkey-cli -p "$PORT_TXN" <<'EOF'
MULTI
SET txn_discard_key will_not_be_set
DISCARD
EOF
)"
    if [[ "$discard_result" == *"OK"* ]]; then
        pass "transactions: DISCARD aborts transaction"
    else
        fail "transactions: DISCARD aborts transaction (got: $discard_result)"
    fi
    local discarded_val
    discarded_val="$(vcli "$PORT_TXN" GET txn_discard_key)"
    if [[ "$discarded_val" == "" ]] || [[ "$discarded_val" == "(nil)" ]]; then
        pass "transactions: key not set after DISCARD"
    else
        fail "transactions: key not set after DISCARD (got: $discarded_val)"
    fi

    # WATCH — optimistic locking (no conflict case)
    vcli "$PORT_TXN" SET watch_key 0 >/dev/null
    local watch_result
    watch_result="$(valkey-cli -p "$PORT_TXN" <<'EOF'
WATCH watch_key
MULTI
INCR watch_key
EXEC
EOF
)"
    if [[ "$watch_result" == *"1"* ]]; then
        pass "transactions: WATCH + MULTI/EXEC succeeds when key not modified"
    else
        fail "transactions: WATCH + MULTI/EXEC succeeds when key not modified (got: $watch_result)"
    fi

    stop_test_server "txn" "$PORT_TXN"
}

# ---------------------------------------------------------------------------
# Lua Scripting
# ---------------------------------------------------------------------------
test_op_lua() {
    section_header "Operational Test: Lua Scripting"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping Lua tests"
        return
    fi

    if ! start_test_server "lua" "$PORT_LUA"; then
        fail "lua: server started"
        return
    fi
    pass "lua: server started"

    # Basic EVAL
    local eval_result
    eval_result="$(vcli "$PORT_LUA" EVAL "return 'hello_lua'" 0)"
    if [[ "$eval_result" == "hello_lua" ]]; then
        pass "lua: EVAL returns expected value"
    else
        fail "lua: EVAL returns expected value (got: $eval_result)"
    fi

    # EVAL with keys and args
    vcli "$PORT_LUA" SET lua_key "lua_base" >/dev/null
    local eval_get
    eval_get="$(vcli "$PORT_LUA" EVAL "return redis.call('GET', KEYS[1])" 1 lua_key)"
    if [[ "$eval_get" == "lua_base" ]]; then
        pass "lua: EVAL can call GET via redis.call"
    else
        fail "lua: EVAL can call GET via redis.call (got: $eval_get)"
    fi

    # SCRIPT LOAD + EVALSHA
    local sha
    sha="$(vcli "$PORT_LUA" SCRIPT LOAD "return 'loaded_script'")"
    if [[ ${#sha} -eq 40 ]]; then
        pass "lua: SCRIPT LOAD returns SHA1 digest"
    else
        fail "lua: SCRIPT LOAD returns SHA1 digest (got: $sha)"
    fi

    local evalsha_result
    evalsha_result="$(vcli "$PORT_LUA" EVALSHA "$sha" 0)"
    if [[ "$evalsha_result" == "loaded_script" ]]; then
        pass "lua: EVALSHA executes loaded script"
    else
        fail "lua: EVALSHA executes loaded script (got: $evalsha_result)"
    fi

    # Invalid SHA returns NOSCRIPT error
    local noscript
    noscript="$(vcli "$PORT_LUA" EVALSHA "0000000000000000000000000000000000000000" 0)"
    if [[ "$noscript" == *"NOSCRIPT"* ]]; then
        pass "lua: invalid EVALSHA returns NOSCRIPT error"
    else
        fail "lua: invalid EVALSHA returns NOSCRIPT error (got: $noscript)"
    fi

    stop_test_server "lua" "$PORT_LUA"
}

# ---------------------------------------------------------------------------
# Keyspace Notifications
# ---------------------------------------------------------------------------
test_op_keyspace_notifications() {
    section_header "Operational Test: Keyspace Notifications"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping keyspace notification tests"
        return
    fi

    if ! start_test_server "keyspace" "$PORT_KEYSPACE" \
            --notify-keyspace-events "KEA"; then
        fail "keyspace notifications: server started"
        return
    fi
    pass "keyspace notifications: server started"

    # Subscribe to keyspace events in background
    local ks_out="$TEST_TMP_DIR/keyspace/ks.out"
    timeout 5 valkey-cli -p "$PORT_KEYSPACE" \
        PSUBSCRIBE '__keyevent@0__:*' >"$ks_out" 2>&1 &
    local ks_pid=$!
    sleep 0.5

    # Trigger a SET, DEL, and expire
    vcli "$PORT_KEYSPACE" SET ks_testkey "v1" >/dev/null
    vcli "$PORT_KEYSPACE" DEL ks_testkey >/dev/null
    vcli "$PORT_KEYSPACE" SET ks_expkey "v2" >/dev/null
    vcli "$PORT_KEYSPACE" EXPIRE ks_expkey 1 >/dev/null
    sleep 0.5

    kill "$ks_pid" 2>/dev/null || true
    wait "$ks_pid" 2>/dev/null || true

    if grep -q "set" "$ks_out" 2>/dev/null; then
        pass "keyspace notifications: SET event received"
    else
        fail "keyspace notifications: SET event received (output: $(cat "$ks_out" 2>/dev/null | tr '\n' ' '))"
    fi

    if grep -q "del" "$ks_out" 2>/dev/null; then
        pass "keyspace notifications: DEL event received"
    else
        fail "keyspace notifications: DEL event received"
    fi

    if grep -q "expire" "$ks_out" 2>/dev/null; then
        pass "keyspace notifications: EXPIRE event received"
    else
        fail "keyspace notifications: EXPIRE event received"
    fi

    stop_test_server "keyspace" "$PORT_KEYSPACE"
}

# ---------------------------------------------------------------------------
# Unix Socket
# ---------------------------------------------------------------------------
test_op_unix_socket() {
    section_header "Operational Test: Unix Socket"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping Unix socket tests"
        return
    fi

    local socket_path="$TEST_TMP_DIR/unix-socket/valkey.sock"
    mkdir -p "$(dirname "$socket_path")"

    if ! start_test_server "unix-tcp" "$PORT_UNIX_TCP" \
            --unixsocket "$socket_path" \
            --unixsocketperm 770; then
        fail "unix socket: server started with unix socket"
        return
    fi
    pass "unix socket: server started with unix socket"

    # Verify socket file exists
    if [[ -S "$socket_path" ]]; then
        pass "unix socket: socket file exists at $socket_path"
    else
        fail "unix socket: socket file exists at $socket_path"
    fi

    # Connect via socket
    local sock_ping
    sock_ping="$(valkey-cli -s "$socket_path" PING 2>&1)"
    if [[ "$sock_ping" == "PONG" ]]; then
        pass "unix socket: PING via unix socket → PONG"
    else
        fail "unix socket: PING via unix socket → PONG (got: $sock_ping)"
    fi

    # SET/GET via socket
    valkey-cli -s "$socket_path" SET __sock_key__ "sock_val" >/dev/null 2>&1
    local sock_val
    sock_val="$(valkey-cli -s "$socket_path" GET __sock_key__ 2>&1)"
    if [[ "$sock_val" == "sock_val" ]]; then
        pass "unix socket: SET/GET via unix socket"
    else
        fail "unix socket: SET/GET via unix socket (got: $sock_val)"
    fi

    stop_test_server "unix-tcp" "$PORT_UNIX_TCP"
}

# ---------------------------------------------------------------------------
# Memory Eviction
# ---------------------------------------------------------------------------
test_op_eviction() {
    section_header "Operational Test: Memory Eviction"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping eviction tests"
        return
    fi

    # Start with a tight maxmemory and allkeys-lru policy
    if ! start_test_server "eviction" "$PORT_EVICTION" \
            --maxmemory 5mb \
            --maxmemory-policy allkeys-lru; then
        fail "eviction: server started with maxmemory=5mb"
        return
    fi
    pass "eviction: server started with maxmemory=5mb allkeys-lru"

    # Fill memory well past the 5 MB limit. 10 000 unique keys × 4 KiB ≈
    # 40 MB of value bytes, far more than the cap even allowing for
    # hashtable overhead. Use valkey-benchmark with -P 32 pipelining rather
    # than forking one valkey-cli per SET (which is painfully slow in a
    # container). -r ensures distinct keys so eviction has something to
    # choose from, -d sets value size, -t set restricts to SET only.
    valkey-benchmark -p "$PORT_EVICTION" \
        -n 10000 -r 10000 -d 4096 -P 32 -t set -q >/dev/null 2>&1 || true

    # Server must still be responding (no crash)
    local evict_ping
    evict_ping="$(vcli "$PORT_EVICTION" PING)"
    if [[ "$evict_ping" == "PONG" ]]; then
        pass "eviction: server still alive after filling memory past limit"
    else
        fail "eviction: server still alive after filling memory past limit (got: $evict_ping)"
    fi

    # Verify evictions occurred
    local evicted_keys
    evicted_keys="$(info_field "$PORT_EVICTION" "evicted_keys")"
    if [[ "$evicted_keys" =~ ^[0-9]+$ ]] && [[ "$evicted_keys" -gt 0 ]]; then
        pass "eviction: evicted_keys > 0 ($evicted_keys keys evicted)"
    else
        fail "eviction: evicted_keys > 0 (got: $evicted_keys)"
    fi

    # Used memory should not massively exceed maxmemory
    local used_mem
    used_mem="$(info_field "$PORT_EVICTION" "used_memory")"
    local max_mem_bytes=$((8 * 1024 * 1024))  # allow some overhead above 5mb
    if [[ "$used_mem" =~ ^[0-9]+$ ]] && [[ "$used_mem" -lt "$max_mem_bytes" ]]; then
        pass "eviction: used_memory ($used_mem bytes) within acceptable range"
    else
        fail "eviction: used_memory ($used_mem bytes) exceeds expected ceiling ($max_mem_bytes bytes)"
    fi

    stop_test_server "eviction" "$PORT_EVICTION"
}

# ---------------------------------------------------------------------------
# Slow Log
# ---------------------------------------------------------------------------
test_op_slowlog() {
    section_header "Operational Test: Slow Log"

    if ! command -v valkey-server &>/dev/null; then
        skip "valkey-server not in PATH — skipping slow log tests"
        return
    fi

    # Set a very low threshold so all commands are logged
    if ! start_test_server "slowlog" "$PORT_SLOWLOG" \
            --slowlog-log-slower-than 0 \
            --slowlog-max-len 128; then
        fail "slowlog: server started with slowlog-log-slower-than=0"
        return
    fi
    pass "slowlog: server started with slowlog-log-slower-than=0"

    # Run a few commands
    vcli "$PORT_SLOWLOG" SET slow_key hello >/dev/null
    vcli "$PORT_SLOWLOG" GET slow_key >/dev/null
    vcli "$PORT_SLOWLOG" INCR slow_counter >/dev/null

    # SLOWLOG LEN
    local slow_len
    slow_len="$(vcli "$PORT_SLOWLOG" SLOWLOG LEN)"
    if [[ "$slow_len" =~ ^[0-9]+$ ]] && [[ "$slow_len" -gt 0 ]]; then
        pass "slowlog: SLOWLOG LEN > 0 ($slow_len entries)"
    else
        fail "slowlog: SLOWLOG LEN > 0 (got: $slow_len)"
    fi

    # SLOWLOG GET returns entries
    local slow_get
    slow_get="$(vcli "$PORT_SLOWLOG" SLOWLOG GET 5)"
    if [[ "$slow_get" != "(empty array)" ]] && [[ -n "$slow_get" ]]; then
        pass "slowlog: SLOWLOG GET returns entries"
    else
        fail "slowlog: SLOWLOG GET returns entries (empty)"
    fi

    # SLOWLOG RESET
    vcli "$PORT_SLOWLOG" SLOWLOG RESET >/dev/null
    slow_len="$(vcli "$PORT_SLOWLOG" SLOWLOG LEN)"
    # After RESET, len should be 0 or 1 (the RESET command itself may be logged)
    if [[ "$slow_len" =~ ^[01]$ ]]; then
        pass "slowlog: SLOWLOG RESET clears log"
    else
        fail "slowlog: SLOWLOG RESET clears log (got len: $slow_len)"
    fi

    stop_test_server "slowlog" "$PORT_SLOWLOG"
}

# ---------------------------------------------------------------------------
# Performance Baseline
# ---------------------------------------------------------------------------
test_op_performance() {
    section_header "Operational Test: Performance Baseline"

    if ! command -v valkey-server &>/dev/null || ! command -v valkey-benchmark &>/dev/null; then
        skip "valkey-server or valkey-benchmark not in PATH — skipping performance tests"
        return
    fi

    if ! start_test_server "perf" "$PORT_PERF"; then
        fail "performance: server started"
        return
    fi
    pass "performance: server started"

    # Run benchmark — 10k requests, pipeline 10, single-thread client
    # Minimum threshold: 10k ops/sec (conservative — works in containers)
    local bench_output
    # Strip CRs from the benchmark output. valkey-benchmark -q emits
    # progress updates terminated with \r that get preserved when stdout is
    # captured; without this strip, `grep '^GET'` fails to anchor because
    # the line actually starts with \r.
    bench_output="$(valkey-benchmark -p "$PORT_PERF" -n 10000 -P 10 -q 2>&1 | tr -d '\r')" || true

    # Extract GET throughput
    local get_rps
    # Match only the final "requests per second" summary line, not progress
    # updates. Format: "GET: 769230.75 requests per second, p50=0.311 msec".
    # awk extracts the second whitespace-separated token on the matching
    # line, and we drop the decimal part for integer comparison.
    get_rps="$(echo "$bench_output" \
        | awk '/^GET:.*requests per second/ { print $2; exit }')"
    get_rps="${get_rps%.*}"
    if [[ -n "$get_rps" ]] && [[ "$get_rps" -ge 10000 ]]; then
        pass "performance: GET throughput >= 10k ops/sec ($get_rps ops/sec)"
    elif [[ -n "$get_rps" ]]; then
        fail "performance: GET throughput >= 10k ops/sec (got: $get_rps ops/sec)"
    else
        skip "performance: could not parse GET throughput from benchmark output"
    fi

    # Extract SET throughput
    local set_rps
    set_rps="$(echo "$bench_output" \
        | awk '/^SET:.*requests per second/ { print $2; exit }')"
    set_rps="${set_rps%.*}"
    if [[ -n "$set_rps" ]] && [[ "$set_rps" -ge 10000 ]]; then
        pass "performance: SET throughput >= 10k ops/sec ($set_rps ops/sec)"
    elif [[ -n "$set_rps" ]]; then
        fail "performance: SET throughput >= 10k ops/sec (got: $set_rps ops/sec)"
    else
        skip "performance: could not parse SET throughput from benchmark output"
    fi

    # Memory sanity check
    local used_memory_rss
    used_memory_rss="$(info_field "$PORT_PERF" "used_memory_rss")"
    local max_rss=$((256 * 1024 * 1024))  # 256MB upper bound for idle server
    if [[ "$used_memory_rss" =~ ^[0-9]+$ ]] && [[ "$used_memory_rss" -lt "$max_rss" ]]; then
        pass "performance: used_memory_rss ($used_memory_rss bytes) is within expected bounds"
    else
        fail "performance: used_memory_rss ($used_memory_rss bytes) exceeds expected ceiling ($max_rss bytes)"
    fi

    stop_test_server "perf" "$PORT_PERF"
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    local pass_pct=0
    if [[ $total -gt 0 ]]; then
        pass_pct=$(( (PASS_COUNT * 100) / total ))
    fi

    # Build pass-rate bar (20 chars wide)
    local bar_len=20
    local filled=$(( (PASS_COUNT * bar_len) / (total > 0 ? total : 1) ))
    local empty=$((bar_len - filled))
    local bar_fill="" bar_rest=""
    for ((i=0; i<filled; i++)); do bar_fill+="#"; done
    for ((i=0; i<empty;  i++)); do bar_rest+="-"; done

    printf "\n${BOLD}================================================================${RESET}\n"
    if [[ -n "$EXPECTED_VERSION" ]]; then
        printf "${BOLD}  Test Summary — Percona Valkey %s (%s)${RESET}\n" "$EXPECTED_VERSION" "$OS_FAMILY"
    else
        printf "${BOLD}  Test Summary — Percona Valkey (%s)${RESET}\n" "$OS_FAMILY"
    fi
    printf "${BOLD}================================================================${RESET}\n"

    # Packages tested
    printf "\n  ${CYAN}Packages tested:${RESET}\n"
    if [[ ${#INSTALLED_PKGS[@]} -gt 0 ]]; then
        for pkg in "${INSTALLED_PKGS[@]}"; do
            printf "    %-45s\n" "$pkg"
        done
    else
        printf "    (none captured)\n"
    fi

    # Results
    printf "\n  ${CYAN}Results:${RESET}\n"
    printf "    ${GREEN}PASS : %3d${RESET}\n" "$PASS_COUNT"
    printf "    ${RED}FAIL : %3d${RESET}\n" "$FAIL_COUNT"
    printf "    ${YELLOW}SKIP : %3d${RESET}\n" "$SKIP_COUNT"
    printf "    ─────────\n"
    printf "    Total: %3d\n" "$total"

    # Pass rate bar
    printf "\n  ${CYAN}Pass rate:${RESET} [${GREEN}%s${RESET}${RED}%s${RESET}] %d%%\n" \
        "$bar_fill" "$bar_rest" "$pass_pct"

    # Duration
    printf "  ${CYAN}Duration:${RESET}  %dm %02ds\n" "$mins" "$secs"

    # Failed tests detail
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${RED}Failed tests:${RESET}\n"
        for t in "${FAILED_TESTS[@]}"; do
            printf "    ${RED}x${RESET} %s\n" "$t"
        done
    fi

    # Skipped tests detail
    if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}Skipped tests:${RESET}\n"
        for t in "${SKIPPED_TESTS[@]}"; do
            printf "    ${YELLOW}-${RESET} %s\n" "$t"
        done
    fi

    printf "\n${BOLD}================================================================${RESET}\n"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        printf "${RED}${BOLD}  RESULT: FAILED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 1
    else
        printf "${GREEN}${BOLD}  RESULT: PASSED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 0
    fi
}

###############################################################################
# Main
###############################################################################
main() {
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --pkg-dir=*)
                PKG_DIR="${arg#*=}"
                INSTALL_MODE="pkg-dir"
                ;;
            --repo)
                INSTALL_MODE="repo"
                ;;
            --repo-channel=*)
                REPO_CHANNEL="${arg#*=}"
                ;;
            --version=*)
                EXPECTED_VERSION="${arg#*=}"
                ;;
            --help|-h)
                echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]"
                echo ""
                echo "Auto-detects OS, installs Percona Valkey packages, runs tests,"
                echo "removes packages, and verifies clean removal."
                echo ""
                echo "Install source (one required):"
                echo "  --pkg-dir=DIR           Directory containing .deb or .rpm packages"
                echo "  --repo                  Install from Percona repository"
                echo ""
                echo "Options:"
                echo "  --repo-channel=CHANNEL  Repo channel: testing (default), release, or experimental"
                echo "  --version=X.Y.Z         Expected Valkey version (auto-detected if omitted)"
                exit 0
                ;;
            *)
                echo "Unknown argument: $arg" >&2
                echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]" >&2
                exit 1
                ;;
        esac
    done

    START_TIME=$(date +%s)

    if [[ -z "$INSTALL_MODE" ]]; then
        echo "ERROR: either --pkg-dir or --repo is required" >&2
        echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]" >&2
        exit 1
    fi

    if [[ "$INSTALL_MODE" == "pkg-dir" ]]; then
        if [[ ! -d "$PKG_DIR" ]]; then
            echo "ERROR: Package directory does not exist: $PKG_DIR" >&2
            exit 1
        fi
        # Resolve to absolute path
        PKG_DIR="$(cd "$PKG_DIR" && pwd)"

        # Auto-detect version from package filenames if not provided
        if [[ -z "$EXPECTED_VERSION" ]]; then
            local pkg_file
            pkg_file="$(find "$PKG_DIR" -maxdepth 1 -name 'percona-valkey-server*' \( -name '*.deb' -o -name '*.rpm' \) | head -1)"
            if [[ -n "$pkg_file" ]]; then
                EXPECTED_VERSION="$(basename "$pkg_file" | grep -oP '[\._-]\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
            fi
        fi
        echo "Package directory: $PKG_DIR"
    else
        echo "Install mode: repo (channel=$REPO_CHANNEL)"
    fi

    if [[ -n "$EXPECTED_VERSION" ]]; then
        echo "Expected version: $EXPECTED_VERSION"
    fi
    detect_os

    # Install
    if [[ "$INSTALL_MODE" == "repo" ]]; then
        install_from_repo_"$OS_FAMILY"
    elif [[ "$OS_FAMILY" == "deb" ]]; then
        install_packages_deb
    else
        install_packages_rpm
    fi

    # Run tests — use set +e so individual failures don't abort
    set +e

    test_binaries
    test_user_group
    test_directories
    test_config_files
    test_systemd_unit_files
    test_systemd_service_hardening
    test_systemd_enable_disable
    test_systemd_start_stop_restart
    test_valkey_server_service
    test_valkey_sentinel_service
    test_systemd_runtime_environment
    test_systemd_restart_on_failure
    test_systemd_targets
    test_systemd_tmpfiles_sysctl
    test_compat_redis
    test_dev_headers
    test_logrotate

    # Stop any lingering services before operational tests
    if has_systemd; then
        if [[ "$OS_FAMILY" == "deb" ]]; then
            systemctl stop valkey-server valkey-sentinel 2>/dev/null || true
        else
            systemctl stop valkey@default valkey-sentinel@default 2>/dev/null || true
        fi
        sleep 1
    fi

    # Operational smoke tests
    setup_operational_tests

    test_op_replication
    test_op_sentinel_failover
    test_op_cluster
    test_op_persistence
    test_op_acl
    test_op_tls
    test_op_config_reload
    test_op_multi_instance
    test_op_pubsub
    test_op_streams
    test_op_transactions
    test_op_lua
    test_op_keyspace_notifications
    test_op_unix_socket
    test_op_eviction
    test_op_slowlog
    test_op_performance

    cleanup_operational_tests

    # Stop any lingering services before removal
    if has_systemd; then
        if [[ "$OS_FAMILY" == "deb" ]]; then
            systemctl stop valkey-server valkey-sentinel 2>/dev/null || true
        else
            systemctl stop valkey@default valkey-sentinel@default 2>/dev/null || true
        fi
        sleep 1
    fi

    set -e

    # Remove
    if [[ "$OS_FAMILY" == "deb" ]]; then
        remove_packages_deb
    else
        remove_packages_rpm
    fi

    # Verify clean removal
    set +e
    test_clean_removal
    set -e

    # Summary
    print_summary
}

main "$@"
