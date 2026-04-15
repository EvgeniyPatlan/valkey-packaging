# percona-valkey-packaging

OS packaging (DEB/RPM) for [Percona Valkey](https://valkey.io) — a Percona-branded distribution of the Valkey key-value store.

## Repository structure

```
valkey-packaging/
  scripts/
    valkey_builder.sh       # Main build driver (RPM & DEB)
    test_packages.sh        # Package validation test suite
    test_in_docker.sh       # Multi-OS Docker test runner
  debian/                   # Debian packaging (control, rules, patches, etc.)
  rpm/
    percona-valkey.spec     # Percona-branded RPM spec
    valkey.spec             # Upstream community RPM spec
```

## Prerequisites

Build dependencies can be installed automatically with the `--install_deps` flag (requires root), or manually:

**RPM-based systems (RHEL, Rocky, Oracle, Amazon Linux, Fedora, SUSE):**

```
rpm-build rpmdevtools gcc make wget tar gzip git
jemalloc-devel openssl-devel pkgconfig
python3 tcl procps-ng systemd-devel
```

**DEB-based systems (Debian, Ubuntu):**

```
build-essential debhelper devscripts dh-exec dpkg-dev fakeroot
libjemalloc-dev libssl-dev libsystemd-dev libhiredis-dev
liblua5.1-dev liblzf-dev pkg-config tcl tcl-dev openssl
```

## Building packages

All builds use `scripts/valkey_builder.sh`. A build directory (`--builddir`) is required and must differ from the current working directory.

### Full RPM build (on an RPM-based host)

```bash
mkdir -p /tmp/BUILD

scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_src_rpm \
  --build_rpm \
  --install_deps \
  --version=9.1.0 \
  --branch=9.1
```

Output RPMs are placed in `/tmp/BUILD/rpm/` and in the current directory under `rpm/`.

> **Note:** upstream Valkey 9.1.0 is not yet tagged, so `--branch=9.1` checks out the
> `9.1` development branch from `valkey-io/valkey` while the resulting package is
> labelled `9.1.0`. Update to `--branch=9.1.0` once upstream tags the release.

### Full DEB build (on a Debian/Ubuntu host)

```bash
mkdir -p /tmp/BUILD

scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_src_deb \
  --build_deb \
  --install_deps \
  --version=9.1.0 \
  --branch=9.1
```

Output .deb files are placed in `/tmp/BUILD/deb/` and in the current directory under `deb/`.

### Using local packaging scripts

By default the builder clones packaging scripts from GitHub. To use the `debian/` and `rpm/` directories from this repository instead:

```bash
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_rpm \
  --install_deps \
  --use_local_packaging_script
```

### Builder flags reference

| Flag | Description |
|------|-------------|
| `--builddir=DIR` | **Required.** Working directory for the build |
| `--get_sources` | Clone Valkey source from `--repo` at `--branch` |
| `--build_src_rpm` | Build source RPM |
| `--build_rpm` | Build binary RPMs (requires source RPM) |
| `--build_src_deb` | Build source DEB package |
| `--build_deb` | Build binary DEB packages (requires source DEB) |
| `--install_deps` | Install build dependencies (requires root) |
| `--version=VER` | Version string (default: `9.1.0`) |
| `--release=REL` | Release number (default: `1`) |
| `--branch=BRANCH` | Git branch/tag to check out (default: `9.1`) |
| `--repo=URL` | Source repository URL (default: `https://github.com/valkey-io/valkey.git`) |
| `--use_local_packaging_script` | Use `debian/` and `rpm/` from this repo instead of cloning |

## Testing packages

### `test_packages.sh` — single-host test suite

Runs on the current host. Auto-detects OS family (DEB vs RPM), installs packages, runs validation tests, removes packages, and verifies clean removal. Requires root.

**Test from locally built packages:**

```bash
sudo bash scripts/test_packages.sh --pkg-dir=/tmp/BUILD/deb
```

**Test from Percona repository:**

```bash
sudo bash scripts/test_packages.sh --repo --repo-channel=testing
```

**Test flags:**

| Flag | Description |
|------|-------------|
| `--pkg-dir=DIR` | Install from local .deb/.rpm files in DIR |
| `--repo` | Install from Percona repository |
| `--repo-channel=CHANNEL` | Repo channel: `testing` (default), `release`, or `experimental` |
| `--version=X.Y.Z` | Expected Valkey version (auto-detected from package filenames if omitted) |

**Test categories executed:**

- Binary installation (valkey-server, valkey-cli, valkey-sentinel, valkey-benchmark, valkey-check-aof, valkey-check-rdb)
- User/group creation (`valkey` user and group)
- Directory structure (`/var/lib/valkey`, `/var/log/valkey`, `/etc/valkey`, `/run/valkey`)
- Configuration files
- Systemd unit files and service hardening (ProtectSystem, PrivateTmp, NoNewPrivileges, etc.)
- Systemd enable/disable, start/stop/restart
- Valkey server functional tests (PING, SET/GET, CONFIG, INFO, persistence)
- Valkey sentinel functional tests
- Runtime environment (PID file, socket, process user)
- Restart-on-failure behavior
- Systemd targets and tmpfiles/sysctl
- Redis compatibility symlinks (`redis-cli`, `redis-server`, etc.)
- Development headers (`valkey/valkey-module.h`)
- Logrotate configuration
- Clean removal verification

### `test_in_docker.sh` — multi-OS Docker test matrix

Launches systemd-enabled Docker containers, copies packages in, runs `test_packages.sh`, and reports a summary table.

**Single image, repo-based:**

```bash
scripts/test_in_docker.sh --repo --image=ubuntu:24.04
```

**Single image, local packages:**

```bash
scripts/test_in_docker.sh --pkg-dir=./build/deb --image=debian:bookworm
```

**Full matrix (all supported images):**

```bash
scripts/test_in_docker.sh --pkg-dir=./build/deb --all
```

**Run directly on host (no Docker):**

```bash
scripts/test_in_docker.sh --repo --no-docker
```

**Docker test flags:**

| Flag | Description |
|------|-------------|
| `--pkg-dir=DIR` | Install from local .deb/.rpm files in DIR |
| `--repo` | Install from Percona repository |
| `--repo-channel=CHANNEL` | Repo channel: `testing` (default), `release`, or `experimental` |
| `--image=IMAGE` | Run on a single Docker image (e.g. `ubuntu:24.04`) |
| `--all` | Run on all supported images matching the package type |
| `--no-docker` | Run `test_packages.sh` directly on the current host |
| `--version=X.Y.Z` | Expected Valkey version (passed to `test_packages.sh`) |
| `--keep` | Don't remove containers after run (useful for debugging) |

**Supported Docker images:**

| Family | Images |
|--------|--------|
| DEB | `ubuntu:24.04`, `debian:bookworm` |
| RPM | `rockylinux:9`, `oraclelinux:9`, `amazonlinux:2023` |

## Supported platforms

### DEB packages

| Distribution | Architectures |
|-------------|---------------|
| Ubuntu 24.04 (Noble) | x86_64, aarch64 |
| Debian 12 (Bookworm) | x86_64, aarch64 |

### RPM packages

| Distribution | Architectures |
|-------------|---------------|
| RHEL / Rocky / Alma 9 | x86_64, aarch64 |
| Oracle Linux 9 | x86_64, aarch64 |
| Amazon Linux 2023 | x86_64, aarch64 |
| Fedora (latest) | x86_64, aarch64 |
| openSUSE / SLES | x86_64, aarch64 |

### DEB packages produced

| Package | Description |
|---------|-------------|
| `percona-valkey-server` | Server binary and systemd units |
| `percona-valkey-sentinel` | Sentinel binary and systemd unit |
| `percona-valkey-tools` | CLI, benchmark, check-aof, check-rdb |
| `percona-valkey-dev` | Module development headers |
| `percona-valkey-compat-redis` | Redis compatibility symlinks |
| `percona-valkey-compat-redis-dev` | Redis compatibility dev headers |
| `percona-valkey-doc` | Documentation |

## License

Valkey is released under the [BSD 3-Clause License](https://github.com/valkey-io/valkey/blob/unstable/LICENSE.txt).
