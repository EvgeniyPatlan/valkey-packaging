# percona-valkey-admin

Hand-authored RPM and DEB packaging, built from the upstream valkey-admin
release archive in per-distro containers.

## Naming

The package and its install root carry the `percona-` brand: source package
`percona-valkey-admin`, binary package `percona-valkey-admin-server`, payload
root `/usr/lib/percona-valkey-admin-server`. The operator-facing interface
does not: systemd unit `valkey-admin.service`, config directory
`/etc/valkey-admin` (env file `valkey-admin.env`), data directory
`/var/lib/valkey-admin`, and the `valkey-admin` system user/group all keep
their unbranded names, so an operator's existing unit overrides, config
paths and permissions keep working across the rename.

## Where the source comes from

Unlike a typical checkout-adjacent packaging tree, this directory has no
sibling valkey-admin working copy to build from. `rpm/build-rpm.sh` and
`build-deb.sh` both fetch the upstream release archive for `PACKAGE_VERSION`
(`lib/fetch-source.sh`) --
`https://github.com/valkey-io/valkey-admin/archive/refs/tags/v<version>/valkey-admin-<version>.tar.gz`
-- and cache it under `.cache/` so all nine targets share one download.
`rpm/percona-valkey-admin.spec`'s `Source0` names the same URL for
provenance; rpmbuild itself never fetches it; `rpm/build-rpm.sh` supplies the
cached copy into `SOURCES` under the basename Source0 expects.

The archive does not contain a `packaging/` directory on any version -- it
never has -- so everything this packaging installs, ships as documentation,
or executes against the extracted source that isn't part of the upstream
tree is supplied from this directory instead, as numbered RPM Sources
(`Source1`-`Source6`: the sysusers fragment, the systemd unit, the tmpfiles
fragment, the env file, `README.packaging.md`, and the
`common/build-server-payload.sh` build helper) or, on the DEB side, by
bind-mounting this whole directory into the build container read-only at
`/packaging` and having `debian/rules` reach into it by absolute path (see
that file).

`build-deb.sh` additionally repacks the cached archive as
`percona-valkey-admin_<version>.orig.tar.gz`, the naming `debian/source/format`'s
"3.0 (quilt)" expects for a non-native source package. The build itself runs
`dpkg-buildpackage -us -uc -b` (binary only), which does not invoke
`dpkg-source` and so does not strictly require the orig tarball to be
present -- it is produced anyway so a real, reproducible source package
could be built from the same inputs if one is ever wanted, rather than a
working-tree snapshot standing in for it.

## `%doc`/`.docs`: README.packaging.md ships in both packages

Both packages ship this file as documentation (`%doc README.packaging.md` in
the spec, listed in `debian/percona-valkey-admin-server.docs`), the same way
`bloom/` and `json/` ship their own `README.packaging.md` in this repo.
`bundle/` is the one product directory here that does not -- it is a
dependency-only meta-package with no `README.packaging.md` at all, not an
instance of this convention being skipped.

Shipping it keeps a real coupling alive: `tests/test-artifact-provenance.sh`
treats this file as a package-content input, so an edit to it makes every
previously built
artifact look stale and forces a rebuild before the suite will call them
trustworthy again. Dropping it from `%doc`/`.docs` would not by itself break
that guard -- `CONTENT_INPUTS` can track a file regardless of whether it is
installed -- but it would remove the reason the coupling matters: right now,
an edit to this file is also an edit to what ships inside the package, which
is exactly the class of change the provenance guard exists to catch.

## Prerequisite: Node.js >= 20 on target hosts

`percona-valkey-admin-server` requires Node.js 20 or later. Node 18 is not supported:
the application was measured to run correctly on 18.20.8, but 18 is end of
life and the build targets Node 22.

The dependency each package ships is not a plain "Node >= 20" — the RPM form
in particular needs an epoch qualifier to actually enforce that floor:

- **DEB**: `nodejs (>= 20)`. No epoch is in play on Debian/Ubuntu, so this is
  sufficient on its own.
- **RPM**: `(nodejs >= 1:20 or nodejs22 >= 1:22)`. Every EL/Fedora/Amazon
  `nodejs` package carries `Epoch: 1`, and rpm lets epoch dominate version
  comparison completely: an unqualified requirement like `nodejs >= 20` is
  satisfied by the epoch-1 provider `nodejs = 1:18.12.1` — and the same
  holds even for a requirement as strict-looking as an unqualified
  `nodejs >= 99`, since the epoch alone already outranks the implicit
  epoch 0 on the requirement and the version number named in it is never
  reached. Both branches of the dependency are pinned to epoch 1, not just
  the first one. The `or nodejs22` branch exists because Amazon Linux 2023
  provides no bare `nodejs` capability at all from its `nodejs22` package —
  the bare `nodejs` capability there is supplied only by node 18, so the
  versioned alternative is what a Node-22 install on that distro can
  actually satisfy.

Distro coverage — these targets satisfy the floor from their own archives:
EL8 (after `dnf module enable nodejs:22`, the stream this packaging's own
`el8` build image uses; `nodejs:20` is also available and satisfies the
floor if preferred), EL9, EL10, Amazon Linux 2023, and Debian 13.

These do NOT, and need Node >= 20 from the internal repository: Debian 12,
Ubuntu 20.04, Ubuntu 22.04, Ubuntu 24.04.

## Usage

    ./build.sh list                 # show the target table
    ./build.sh image <target>       # build the per-distro build image
    ./build.sh <target> [arch]      # build packages into out/<target>/
    ./build.sh test                 # run the packaging test suite

### What `build.sh test` actually installs

`test-rpm-install.sh` and `test-deb-install.sh` each install a package into a
fresh container and assert on the result; they only ever cover the one
target their defaults name. `build.sh test` runs the full suite once with
those defaults (el9, debian12) and then, for the RPM side, drives
`test-rpm-install.sh` again for `el8` and `amazon2023` — the two other RPM
targets whose install-time behavior no other target exercises (el8 is the
only target whose `%pre` takes the `useradd` branch; amazon2023 is the only
target where the `or nodejs22` half of the dependency is load-bearing). The
default suite therefore installs three of the four RPM targets (el9, el8,
amazon2023) and one of the five DEB targets (debian12).

`el10` and the remaining DEB targets (debian13, ubuntu2004, ubuntu2204,
ubuntu2404) are not installed by the default suite — a full nine-target
install sweep is slow enough that it isn't worth paying for on every run —
but each is reachable directly through the `TEST_TARGET`/`TEST_IMAGE` hooks
the install tests already read from `targets.conf`:

    TEST_TARGET=el10 TEST_IMAGE="rockylinux/rockylinux:10" \
      bash tests/test-rpm-install.sh
    TEST_TARGET=ubuntu2404 TEST_IMAGE="ubuntu:24.04" \
      bash tests/test-deb-install.sh

## Layout constraint

The installed tree must preserve `apps/`. The server bundle resolves its
frontend as `../../frontend/dist` and the collector entry as
`../../metrics/dist/index.cjs`, with no environment override for the frontend
path. `tests/test-server-payload.sh` asserts this.

## Service state after install

The DEB and RPM packages differ in whether the service is running right
after install, and this matters because Web mode's only authentication is a
session cookie:

- **DEB**: debhelper's postinst enables and starts `valkey-admin.service` on
  install, so the server is reachable immediately.
- **RPM**: `%post` runs `%systemd_post`, which only applies the systemd
  preset on first install. The unit is not started, and stays disabled
  unless the preset (or the operator) says otherwise.

Each behavior is idiomatic for its packaging family; an operator relying on
the service being up right after `dnf install` on an RPM target will be
wrong, and should enable and start it explicitly.

## Build note: Ubuntu 20.04

Ubuntu 20.04 (focal) ships debhelper 12.10 in its own archive, below the
`debhelper-compat (= 13)` this packaging requires. The `ubuntu2004` build
image enables `focal-backports`, which carries debhelper 13.

## Packages

- `percona-valkey-admin-server` — headless web server, managed by systemd.
  Provides/Obsoletes (RPM) and Provides/Replaces/Conflicts (DEB) the
  previous `valkey-admin-server` name so an install of this package upgrades
  cleanly over it.
- `percona-valkey-admin` — desktop GUI. Not yet packaged.

## Rename upgrade hazard: purging the obsoleted DEB name

On DEB targets, installing `percona-valkey-admin-server` over an existing
`valkey-admin-server` does not remove the old package the way rpm's
`Obsoletes` does: dpkg's `Replaces`/`Conflicts` deconfigures it, leaving it
in the `rc` (deinstalled, config files remaining) state. The old package's
own `postrm` stays on disk in that state, and it still owns the unbranded
paths both packages share.

If an operator later runs `apt purge valkey-admin-server` against that `rc`
remnant, dpkg's conffile tracking is per source package and genuinely
protects `/etc/valkey-admin/valkey-admin.env` (the live file, owned by
`percona-valkey-admin-server`, survives) — but `/var/lib/valkey-admin` and
the `valkey-admin` system account are **not** conffiles and are **not**
protected by anything. The old `postrm`'s purge branch (`rm -rf
/var/lib/valkey-admin`; `deluser valkey-admin`) runs unconditionally and
deletes both from the live, healthy new install. `percona-valkey-admin-server`
itself stays installed and its payload is untouched — only the data
directory and service account are lost.

`tests/test-upgrade-deb.sh` exercises exactly this sequence and asserts both
halves: the env file survives, and `/var/lib/valkey-admin` plus the
`valkey-admin` user do not. This cannot happen in practice on this
project's own history — no pre-rename `valkey-admin-server` DEB has ever
been published from this packaging — but the mechanism is real dpkg
behavior and would apply to any future rename that reuses unbranded paths
the same way. The pre-rename package this test exercises is a self-contained
fixture (`tests/fixtures/`) that does not depend on the valkey-admin source
at all — see the comment atop `tests/test-upgrade.sh`.

## Releasing

Two files carry the version independently and must be bumped together.
Neither builder trusts you to have done that: each refuses to build when its
package's own version authority disagrees with `lib/fetch-source.sh`'s
`PACKAGE_VERSION`, and each also refuses when its own release/revision digit
disagrees with the other builder's — the RPM `Release:` tag and the DEB
revision (the `-N` suffix in `debian/changelog`) must move together, since
the RPM side depends on `Release` being ahead of whatever it last shipped
(see the `Obsoletes` comment in the spec) and a DEB build left behind at a
stale revision would make this doc's "move together" claim false.

- `lib/fetch-source.sh` — the `PACKAGE_VERSION` both builders read as ground
  truth, and the upstream tag both builders fetch. There is no local
  `package.json` here to derive it from, unlike the working-tree-snapshot
  build this packaging was ported from — `PACKAGE_VERSION` is this
  packaging's own version authority now.
- `debian/changelog` — the DEB's own version authority. Add a new entry at
  the top with `dch` or by hand; `build-deb.sh` compares its first entry's
  version-revision against `PACKAGE_VERSION` and against the RPM spec's
  `Release:` tag, and refuses to build on a mismatch.
- `rpm/percona-valkey-admin.spec` — the `%changelog` section's most recent
  entry is the RPM's own version authority. Add a new entry at the top in
  the same `* <date> <packager> - <version>-<release>` form;
  `rpm/build-rpm.sh` compares it against `PACKAGE_VERSION` and against the
  spec's own `Release:` tag, and refuses to build on a mismatch.

Bump both in the same change before building either package, and confirm the
new tag's release archive exists (`v<version>` under
`valkey-io/valkey-admin`'s tags) before pointing either builder at it — an
unreleased development version's tag archive 404s.
