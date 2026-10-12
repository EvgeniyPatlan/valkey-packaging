# Percona Valkey Admin Docker Images

Two images for the valkey-admin web UI, built the same way as the Valkey server
images in this directory: the package is installed from the Percona repository
rather than built from source, so the image ships exactly what the repository
ships.

| Dockerfile | Base | Tag | Size (1.1.1, amd64) | Node |
|---|---|---|---|---|
| `Dockerfile.admin` | `redhat/ubi9-minimal` (digest-pinned) | `<version>` | ~353 MB | 22 |
| `Dockerfile.admin.hardened` | `dhi.io/debian-base:trixie` (digest-pinned) | `<version>-hardened` | ~182 MB | 20 |

Both run as the unprivileged `valkey-admin` user, expose `8080`, declare
`/var/lib/valkey-admin` as a volume, ship SPDX and CycloneDX SBOMs under
`/usr/local/`, and carry a healthcheck. The hardened image contains no package
manager.

## Security: there is no login

Web mode has **no authentication beyond a session cookie**. The entrypoint sets
`SERVER_BIND_HOST=0.0.0.0` because a container's published port is otherwise
unreachable, which means anyone who can reach the port can administer every
Valkey the UI is connected to. Publish it only on a trusted network or behind
an authenticating proxy, and set `VALKEY_ADMIN_ALLOWED_WS_ORIGINS` to the
origins you actually serve from.

## Build and test

    make build-admin                      # both variants
    make build-admin-rpm                  # UBI9 only
    make build-admin-hardened             # DHI only
    make test-admin                       # both variants
    make build-admin REPO_CHANNEL=release VALKEY_ADMIN_VERSION=1.2.0

`ADMIN_VERSION` (set from `VALKEY_ADMIN_VERSION` by the Makefile) is both the
version label and a build-time assertion: if the repository channel serves a
different version, the build fails rather than producing a mislabelled image.

    docker build --build-arg REPO_CHANNEL=experimental \
                 --build-arg ADMIN_VERSION=1.1.1 \
                 -t perconalab/valkey-admin:1.1.1 -f Dockerfile.admin .

`test-admin-image.sh <image:tag> [rpm|hardened]` is a sibling of
`test-image.sh` rather than another mode inside it: that suite is built around
`valkey-cli ping` against a server image and valkey-admin shares none of its
assertions. It checks the image metadata, that the UI answers 200, that the
process is unprivileged, that a metrics collector starts and serves data, and
that the entrypoint's container configuration took effect.

## Configuration

Every variable below is overridable with `-e`; the values shown are what the
entrypoint defaults to.

| Variable | Default | Notes |
|---|---|---|
| `DEPLOYMENT_MODE` | `Web` | |
| `PORT` | `8080` | |
| `SERVER_BIND_HOST` | `0.0.0.0` | See the security note above |
| `DATA_DIR` | `/var/lib/valkey-admin` | Declared as a volume |
| `CONFIG_PATH` | `$DATA_DIR/metrics-config.yml` | Seeded from the packaged default on first start |
| `VALKEY_HOST`, `VALKEY_PORT` | unset | A preconfigured connection; the UI can also connect at runtime |
| `VALKEY_USERNAME`, `VALKEY_PASSWORD`, `VALKEY_TLS` | unset | |
| `VALKEY_ADMIN_ALLOWED_WS_ORIGINS` | unset | Websocket origin allowlist |

`CONFIG_PATH` must name a file that exists — the metrics collector reads it at
startup and exits if it is missing. The packaged default lives under `/usr`,
which is not writable in either image, so collector-config edits made in the UI
would be lost; the entrypoint therefore points at the data volume and seeds it
from the packaged copy. If the volume is mounted read-only it falls back to the
packaged file, so the collectors still start with shipped defaults.

    docker run -d --name valkey-admin \
      -p 8080:8080 \
      -e VALKEY_HOST=valkey.internal -e VALKEY_PORT=6379 \
      -v valkey-admin-data:/var/lib/valkey-admin \
      perconalab/valkey-admin:1.2.0

## Notes on the two bases

**UBI9.** Node ships as a DNF module on EL9 with no stream enabled by default,
so every modular `nodejs` is hidden by modular filtering and the package's
`(nodejs >= 1:20 or nodejs22 >= 1:22)` cannot resolve — the only visible
provider is a non-modular `nodejs 1:16`, which that floor correctly rejects.
`microdnf -y module enable nodejs:22` is what makes Node 22 installable. The
floor must not be relaxed instead: an unqualified `nodejs >= 20` would match
that Node 16, because the provider's epoch outranks the requirement's implicit
epoch 0, and the service would fail at runtime rather than at install time.

`install_weak_deps=0` keeps `nodejs-docs` (98 MB) and `nodejs-full-i18n` out of
the image. Dropping full-i18n leaves Node with small-icu, so server-side `Intl`
formats with English rules only; the UI formats in the browser.

**DHI.** Debian builds `node` with externalized builtins: it loads JavaScript
out of `/usr/share/nodejs` at startup and aborts with "Cannot load externalized
builtin" without it. `ldd` on the binary cannot reveal that, so the directory is
copied explicitly alongside the ldd-collected libraries — which are gathered for
the native addons in the payload as well as for `node` itself, since
`@valkey/valkey-glide` ships a compiled `.node` module.
