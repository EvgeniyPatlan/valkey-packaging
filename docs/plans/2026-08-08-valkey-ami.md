# Percona Valkey AMI Implementation Plan

**Goal:** Build, verify, and publish four AWS Marketplace AMIs for Percona Valkey 9.1.1 on
Amazon Linux 2023 — `slim` and `bundle` variants across x86_64 and arm64.

**Architecture:** Packer HCL2 defines four `amazon-ebs` sources (variant × architecture) and
two build blocks that share provisioners. All configuration lives in Ansible roles applied
through `ansible-local`, so nothing is AWS-specific except AMI packaging. Per-instance
credentials and memory limits are applied by a systemd unit ordered before
`valkey@default.service`,
so Valkey never starts unconfigured. A bats suite gates AMI creation; a smoke test against a
launched instance gates release.

**Tech Stack:** Packer HCL2 (amazon + ansible plugins), Ansible, bash, bats, Jenkins
declarative pipeline, AWS CLI v2.

**Spec:** `docs/specs/2026-08-08-valkey-ami-design.md`

## Global Constraints

- Valkey version `9.1.1`; repository component `valkey-91`; channel `release` (variable).
- Base OS Amazon Linux 2023 only. Architectures `x86_64` and `arm64`.
- Variants: `slim` installs `percona-valkey`; `bundle` installs `percona-valkey-bundle`.
- Module directory is `/usr/lib64/valkey/modules` on both architectures.
- Root volume 20 GB gp3, unencrypted. Marketplace does not accept encrypted AMIs.
- AMI name format: `percona-valkey-<version>-<variant>-<arch>-<YYYYMMDD-hhmm>`. The time
  is required: AWS rejects duplicate AMI names, so date alone breaks same-day rebuilds.
- Default posture: `bind 127.0.0.1 -::1`, `protected-mode yes`, `maxmemory-policy noeviction`,
  all set in `/etc/valkey/default.conf`.
- Packaging is multi-instance: the unit is the template `valkey@.service`, the canonical
  instance is `valkey@default`, and its config is `/etc/valkey/default.conf`. There is no
  `valkey.service` and no `/etc/valkey/valkey.conf`.
- `maxmemory` is 70% of `MemTotal`, computed at first boot.
- No host firewall. No baked SSH keys, host keys, OS passwords, or credentials.
- No assistant or tooling references in any file, comment, or commit message.
- Comments explain why something is done, never what the next line does.
- All shell passes `shellcheck`; all HCL passes `packer fmt -check`; all Ansible passes
  `ansible-lint`.

---

## Implementation status

Tasks 1 through 7 are implemented on `feat/valkey-ami`. The committed code is the
source of truth for those tasks; the steps below record how they were built and why.

| Task | State | Verified by |
|---|---|---|
| 1 first-boot script | done | 12 unit tests, no AWS required |
| 2 systemd units and tuning | done | `systemd-analyze verify` |
| 3 repo and install roles | done | both variants in an AL2023 container, `release` channel |
| 4 tuning and first-boot roles | done | boot simulation in a systemd container |
| 5 cleanup role | done | playbook clean, 36 tasks |
| 6 bats suites | done | 29 of 29 on both variants |
| 7 Packer template and pipeline | done | `packer validate`, all four `-only` selectors resolve |
| 8 smoke test and first build | pending | needs AWS credentials |
| 9 remaining three images | pending | needs AWS credentials |
| 10 Jenkins pipeline run | pending | needs a Jenkins controller |
| 11 Marketplace preparation | pending | needs a seller account |

Divergences from the original plan, all driven by what the packaging and the base
image actually do:

- Static files live in each role's `files/` directory, because `ansible-local`
  uploads only `playbook_dir`.
- The service is `valkey@default.service` and the config is `/etc/valkey/default.conf`.
  There is no `valkey.service` and no `/etc/valkey/valkey.conf`.
- bats is installed from the pinned upstream tarball into `/opt/bats`; Amazon Linux
  2023 has no bats package. It and `ansible-core` are removed before the snapshot.
- Build network identifiers are defaults on the variable declarations rather than an
  auto-loaded vars file, which did not resolve reliably across Packer versions. The
  values are the subnet and security group the existing Percona AMI builds use.
- The password is drawn from `/dev/urandom` rather than `openssl`, removing a
  dependency from the boot path.

---

## File Structure

| Path | Responsibility |
|---|---|
| `images/Makefile` | Local entry points: lint, unit tests, container tests, build |
| `images/README.md` | How to build and test the images |
| `images/ansible/roles/valkey-firstboot/files/valkey-firstboot.sh` | Per-instance credential, memory, and module configuration |
| `images/ansible/roles/valkey-firstboot/files/valkey-firstboot.service` | Ordering guarantee before `valkey@default.service` |
| `images/ansible/roles/valkey-tuning/files/99-valkey.conf` | sysctl values Valkey requires |
| `images/ansible/roles/valkey-tuning/files/valkey-thp.service` | Disables transparent huge pages at boot |
| `images/ansible/roles/valkey-tuning/files/10-limits.conf` | `valkey@.service` drop-in raising `LimitNOFILE` |
| `images/ansible/valkey-ami.yml` | Playbook binding roles in order |
| `images/ansible/roles/valkey-repo/` | GPG keys, `percona-release`, channel enable |
| `images/ansible/roles/valkey-install/` | Variant to package set, version assertion |
| `images/ansible/roles/valkey-tuning/` | Deploys tuning files, enables THP unit |
| `images/ansible/roles/valkey-firstboot/` | Deploys script and unit, locks baseline config |
| `images/ansible/roles/cloud-cleanup/` | Strips identity, secrets, and logs before bake |
| `images/packer/variables.pkr.hcl` | Variable declarations and validation |
| `images/packer/valkey-ami.pkr.hcl` | Four sources, two builds, provisioners, region copy |
| `images/packer/release.pkvars.hcl` | Version, channel, and region list |
| `images/packer/release.pkvars.hcl` | Version, channel, region list |
| `images/test/unit/firstboot.bats` | Unit tests for the first-boot script, run locally |
| `images/test/bats/install.bats` | Bake-time package and service assertions |
| `images/test/bats/config.bats` | Bake-time configuration assertions |
| `images/test/bats/hardening.bats` | Bake-time security assertions |
| `images/test/smoke/smoke.sh` | Post-launch verification against a live instance |
| `images/test/container/run.sh` | Applies the playbook in a systemd-enabled AL2023 container |
| `rel/jenkins/valkey-ami.groovy` | Build matrix, region copy, smoke stage |

The first-boot script is the highest-risk unit and is written to be testable without AWS:
every path it touches is overridable by environment variable, so its bats suite runs against
a temporary directory on any workstation.

Static files live in the `files/` directory of the role that deploys them. Packer's
`ansible-local` provisioner uploads only `playbook_dir`, so anything outside
`images/ansible/` would never reach the build instance.

---

## Task 1: Scaffolding and the first-boot script

The first-boot script carries the credential generation, memory sizing, module loading, and
idempotence logic. It is pure bash with no AWS dependency, so it is built test-first and
fully covered before anything else exists.

**Files:**
- Create: `images/Makefile`
- Create: `images/ansible/roles/valkey-firstboot/files/valkey-firstboot.sh`
- Test: `images/test/unit/firstboot.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `/usr/local/sbin/valkey-firstboot`, which reads these environment variables —
  `VALKEY_FIRSTBOOT_ROOT` (path prefix, default empty), `VALKEY_FIRSTBOOT_MEMINFO`
  (default `/proc/meminfo`), `VALKEY_FIRSTBOOT_MODULE_DIR` (default
  `/usr/lib64/valkey/modules`), `VALKEY_FIRSTBOOT_CONSOLE` (default `/dev/console`),
  `VALKEY_VARIANT` (`slim` or `bundle`, default `slim`). It writes
  `${ROOT}/etc/valkey/valkey-generated.conf`, `${ROOT}/etc/motd.d/30-valkey`, and the marker
  `${ROOT}/etc/valkey/.firstboot-done`. Task 4 installs it; Task 6 asserts its effects.

- [ ] **Step 1: Create the directory tree and Makefile**

```bash
mkdir -p images/{ansible/roles/{valkey-firstboot,valkey-tuning}/files,packer,test/{unit,bats,smoke,container},jenkins}
```

`images/Makefile`:

```make
SHELL := /bin/bash
PACKER ?= packer
VARIANT ?= slim

.PHONY: lint unit container build clean

lint:
	shellcheck ansible/roles/valkey-firstboot/files/valkey-firstboot.sh \
	  test/smoke/smoke.sh test/container/run.sh
	$(PACKER) fmt -check -diff packer/
	ansible-lint ansible/

unit:
	bats test/unit/

container:
	test/container/run.sh $(VARIANT)

build:
	$(PACKER) build -var-file=packer/release.pkvars.hcl packer/

clean:
	rm -rf .packer_cache
```

- [ ] **Step 2: Write the failing unit tests**

`images/test/unit/firstboot.bats`:

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd images && bats test/unit/`
Expected: every test FAILS — the script does not exist yet.

- [ ] **Step 4: Write the script**

`images/ansible/roles/valkey-firstboot/files/valkey-firstboot.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Every path is overridable so the suite in test/unit can exercise this against a
# temporary directory instead of a live system.
ROOT="${VALKEY_FIRSTBOOT_ROOT:-}"
MEMINFO="${VALKEY_FIRSTBOOT_MEMINFO:-/proc/meminfo}"
MODULE_DIR="${VALKEY_FIRSTBOOT_MODULE_DIR:-/usr/lib64/valkey/modules}"
CONSOLE="${VALKEY_FIRSTBOOT_CONSOLE:-/dev/console}"
VARIANT="${VALKEY_VARIANT:-slim}"

CONF_DIR="${ROOT}/etc/valkey"
GENERATED_CONF="${CONF_DIR}/valkey-generated.conf"
MARKER="${CONF_DIR}/.firstboot-done"
MOTD_DIR="${ROOT}/etc/motd.d"
MOTD_FILE="${MOTD_DIR}/30-valkey"

MAXMEMORY_PERCENT=70
PASSWORD_LENGTH=32

generate_password() {
    # Alphanumeric only: valkey.conf gives no special meaning to these characters,
    # so the value never needs quoting or escaping.
    #
    # Reading a fixed chunk before filtering keeps the producer from being killed
    # by SIGPIPE, which would otherwise trip pipefail. The filter discards roughly
    # three quarters of the bytes, so the loop covers a short first draw.
    local candidate=""
    while [ "${#candidate}" -lt "$PASSWORD_LENGTH" ]; do
        candidate+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    done
    printf '%s' "${candidate:0:$PASSWORD_LENGTH}"
}

compute_maxmemory_bytes() {
    local total_kb
    total_kb=$(awk '/^MemTotal:/ { print $2 }' "$MEMINFO")
    echo $(( total_kb * 1024 * MAXMEMORY_PERCENT / 100 ))
}

discover_modules() {
    [ -d "$MODULE_DIR" ] || return 0
    find "$MODULE_DIR" -maxdepth 1 -type f -name '*.so' | sort
}

write_generated_conf() {
    local password="$1" maxmemory="$2"

    {
        echo "requirepass ${password}"
        echo "maxmemory ${maxmemory}"
        echo "maxmemory-policy noeviction"

        if [ "$VARIANT" = "bundle" ]; then
            while IFS= read -r module; do
                echo "loadmodule ${module}"
            done < <(discover_modules)
        fi
    } > "$GENERATED_CONF"

    chmod 0640 "$GENERATED_CONF"
    if [ -z "${VALKEY_FIRSTBOOT_SKIP_CHOWN:-}" ]; then
        # Matches the ownership the package gives default.conf: the server reads
        # its credentials but cannot rewrite them.
        chown root:valkey "$GENERATED_CONF"
    fi
}

write_banner() {
    local password="$1" banner

    banner=$(cat <<EOF

+++++++++++++++++++++++++++ Percona Valkey +++++++++++++++++++++++++++

  A unique password was generated for this instance:

      ${password}

  Connect with:  valkey-cli -a '${password}'

  Valkey listens on localhost only. Review /etc/valkey/default.conf
  before exposing it, and change this password once setup is complete.

+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF
)

    mkdir -p "$MOTD_DIR"
    printf '%s\n' "$banner" > "$MOTD_FILE"
    chmod 0644 "$MOTD_FILE"

    # Reaching the console puts the password in the EC2 system log, which is the
    # only way to recover it when SSH access is not yet working.
    printf '%s\n' "$banner" > "$CONSOLE" 2>/dev/null || true
}

main() {
    if [ -e "$MARKER" ]; then
        return 0
    fi

    mkdir -p "$CONF_DIR"

    local password maxmemory
    password=$(generate_password)
    maxmemory=$(compute_maxmemory_bytes)

    write_generated_conf "$password" "$maxmemory"
    write_banner "$password"

    touch "$MARKER"
}

main "$@"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd images && bats test/unit/`
Expected: all 12 tests PASS.

- [ ] **Step 6: Lint**

Run: `cd images && shellcheck ansible/roles/valkey-firstboot/files/valkey-firstboot.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add images/Makefile images/ansible/roles/valkey-firstboot/files/valkey-firstboot.sh images/test/unit/firstboot.bats
git commit -m "feat(images): add first-boot configuration script

Generates a per-instance password, sizes maxmemory from detected memory,
and loads bundle modules by enumerating the module directory. Guarded by a
marker file so reboots preserve the generated credentials."
```

---

## Task 2: systemd units and tuning files

**Files:**
- Create: `images/ansible/roles/valkey-firstboot/files/valkey-firstboot.service`
- Create: `images/ansible/roles/valkey-tuning/files/99-valkey.conf`
- Create: `images/ansible/roles/valkey-tuning/files/valkey-thp.service`
- Create: `images/ansible/roles/valkey-tuning/files/10-limits.conf`

**Interfaces:**
- Consumes: `/usr/local/sbin/valkey-firstboot` from Task 1.
- Produces: units `valkey-firstboot.service` and `valkey-thp.service`, both ordered before
  `valkey@default.service`; sysctl file `/etc/sysctl.d/99-valkey.conf`; drop-in
  `/etc/systemd/system/valkey@.service.d/10-limits.conf`. Task 4 installs all four; Task 6
  asserts them.

- [ ] **Step 1: Write the first-boot unit**

`images/ansible/roles/valkey-firstboot/files/valkey-firstboot.service`:

```ini
[Unit]
Description=Generate per-instance Percona Valkey configuration
Documentation=https://docs.percona.com/
Before=valkey@default.service
After=local-fs.target
ConditionPathExists=!/etc/valkey/.firstboot-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/valkey-firstboot
Environment=VALKEY_VARIANT=slim

[Install]
WantedBy=multi-user.target
```

The `VALKEY_VARIANT` value is rewritten per variant by the role in Task 4.

- [ ] **Step 2: Write the tuning files**

`images/ansible/roles/valkey-tuning/files/99-valkey.conf`:

```
vm.overcommit_memory = 1
net.core.somaxconn = 1024
```

`images/ansible/roles/valkey-tuning/files/valkey-thp.service`:

```ini
[Unit]
Description=Disable transparent huge pages for Percona Valkey
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=valkey@default.service
ConditionPathExists=/sys/kernel/mm/transparent_hugepage/enabled

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'

[Install]
WantedBy=basic.target
```

`images/ansible/roles/valkey-tuning/files/10-limits.conf`:

```ini
[Service]
LimitNOFILE=65535
```

- [ ] **Step 3: Verify the units parse**

Run:
```bash
cd images && systemd-analyze verify \
  ansible/roles/valkey-firstboot/files/valkey-firstboot.service \
  ansible/roles/valkey-tuning/files/valkey-thp.service
```
Expected: no errors about syntax or unknown directives. One message is expected on a
workstation — `Command /usr/local/sbin/valkey-firstboot is not executable` — because the
script is only installed onto the image, by the role in Task 4.

To confirm that message is the only outstanding issue, verify against a copy whose
`ExecStart` points at the script in the working tree:

```bash
T=$(mktemp -d)
cp ansible/roles/valkey-firstboot/files/valkey-firstboot.service ansible/roles/valkey-tuning/files/valkey-thp.service "$T/"
mkdir -p "$T/fakeroot/usr/local/sbin"
install -m0755 ansible/roles/valkey-firstboot/files/valkey-firstboot.sh "$T/fakeroot/usr/local/sbin/valkey-firstboot"
sed -i "s|ExecStart=/usr/local/sbin/valkey-firstboot|ExecStart=$T/fakeroot/usr/local/sbin/valkey-firstboot|" \
    "$T/valkey-firstboot.service"
systemd-analyze verify "$T/valkey-firstboot.service" "$T/valkey-thp.service"
rm -rf "$T"
```
Expected: exit status 0 with no output.

- [ ] **Step 4: Commit**

```bash
git add images/ansible/roles/valkey-firstboot/files/ images/ansible/roles/valkey-tuning/files/
git commit -m "feat(images): add first-boot unit and kernel tuning

Orders configuration generation and THP disabling ahead of valkey@default.service
so the server never starts unconfigured or with transparent huge pages on."
```

---

## Task 3: Repository and package installation roles

**Files:**
- Create: `images/ansible/roles/valkey-repo/tasks/main.yml`
- Create: `images/ansible/roles/valkey-repo/defaults/main.yml`
- Create: `images/ansible/roles/valkey-install/tasks/main.yml`
- Create: `images/ansible/roles/valkey-install/defaults/main.yml`
- Create: `images/ansible/roles/valkey-install/vars/main.yml`
- Create: `images/ansible/valkey-ami.yml`
- Create: `images/test/container/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: playbook variables `valkey_version` (string, default `9.1.1`),
  `valkey_repo_channel` (string, default `release`), `valkey_variant` (string, `slim` or
  `bundle`, default `slim`). Tasks 4 and 5 add roles to the same playbook.

- [ ] **Step 1: Write the repository role**

`images/ansible/roles/valkey-repo/defaults/main.yml`:

```yaml
---
valkey_repo_channel: release
valkey_repo_component: valkey-91
```

`images/ansible/roles/valkey-repo/tasks/main.yml`:

```yaml
---
- name: Import the Percona packaging key
  ansible.builtin.rpm_key:
    key: https://repo.percona.com/yum/PERCONA-PACKAGING-KEY
    fingerprint: 4D1BB29D63D98E422B2113B19334A25F8507EFA5
    state: present

- name: Download the percona-release package
  ansible.builtin.get_url:
    url: https://repo.percona.com/yum/percona-release-latest.noarch.rpm
    dest: /tmp/percona-release.rpm
    mode: "0644"

- name: Verify the percona-release signature
  ansible.builtin.command: rpmkeys --checksig /tmp/percona-release.rpm
  changed_when: false

- name: Install percona-release
  ansible.builtin.dnf:
    name: /tmp/percona-release.rpm
    state: present
    disable_gpg_check: false

- name: Disable all Percona repositories
  ansible.builtin.command: percona-release disable all
  changed_when: true

- name: Enable the Valkey repository channel
  ansible.builtin.command: >-
    percona-release enable {{ valkey_repo_component }} {{ valkey_repo_channel }}
  changed_when: true

- name: Remove the downloaded percona-release package
  ansible.builtin.file:
    path: /tmp/percona-release.rpm
    state: absent
```

- [ ] **Step 2: Write the install role**

`images/ansible/roles/valkey-install/defaults/main.yml`:

```yaml
---
valkey_variant: slim
valkey_version: 9.1.1
```

`images/ansible/roles/valkey-install/vars/main.yml`:

```yaml
---
# On RPM systems the server, sentinel, and CLI tools ship in a single package.
# The -server/-sentinel/-tools split exists only on DEB.
valkey_variant_packages:
  slim:
    - percona-valkey
  bundle:
    - percona-valkey-bundle
```

`images/ansible/roles/valkey-install/tasks/main.yml`:

```yaml
---
- name: Assert the requested variant is known
  ansible.builtin.assert:
    that: valkey_variant in valkey_variant_packages
    fail_msg: >-
      Unknown variant '{{ valkey_variant }}';
      expected one of {{ valkey_variant_packages.keys() | list | join(', ') }}

- name: Install the Valkey packages for this variant
  ansible.builtin.dnf:
    name: "{{ valkey_variant_packages[valkey_variant] }}"
    state: present

- name: Query the installed Valkey version
  ansible.builtin.command: rpm -q --queryformat '%{VERSION}' percona-valkey
  register: valkey_installed
  changed_when: false

- name: Assert the installed version matches the requested version
  ansible.builtin.assert:
    that: valkey_installed.stdout == valkey_version
    fail_msg: >-
      Installed percona-valkey {{ valkey_installed.stdout }},
      but {{ valkey_version }} was requested from the
      '{{ valkey_repo_channel }}' channel
```

No task disables sentinel. The RPM's `%systemd_post` runs `systemctl preset`, which does not
enable it, so sentinel ships installed and inactive with no action needed. `install.bats`
asserts that rather than a role enforcing it.

- [ ] **Step 3: Write the playbook**

`images/ansible/valkey-ami.yml`:

```yaml
---
- name: Build the Percona Valkey image
  hosts: all
  become: true
  gather_facts: true
  roles:
    - valkey-repo
    - valkey-install
```

- [ ] **Step 4: Write the container test runner**

`images/test/container/run.sh`:

```bash
#!/bin/bash
set -euo pipefail

VARIANT="${1:-slim}"
IMAGE="amazonlinux:2023"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

docker run --rm \
    -v "$WORKDIR":/images:ro \
    -w /images \
    "$IMAGE" \
    bash -c "
        set -euo pipefail
        dnf -y install ansible-core bats findutils procps-ng shadow-utils >/dev/null
        ansible-playbook -i localhost, -c local ansible/valkey-ami.yml \
            -e valkey_variant=${VARIANT} \
            -e valkey_repo_channel=\${VALKEY_REPO_CHANNEL:-release}
    "
```

The container has no running systemd, so service state is not exercised here — Task 8
covers that on a real instance. What this loop does prove, quickly and without AWS, is that
the repository is reachable, the package set resolves, and the version assertion holds.

- [ ] **Step 5: Run the container test**

Run: `cd images && chmod +x test/container/run.sh && make container VARIANT=slim`
Expected: the playbook completes with `failed=0`.

If the version assertion fails because 9.1.1 has not been promoted, rerun with
`VALKEY_REPO_CHANNEL=testing make container` and record which channel was used.

- [ ] **Step 6: Repeat for the bundle variant**

Run: `cd images && make container VARIANT=bundle`
Expected: `failed=0`, and `percona-valkey-bundle` pulls in json, bloom, search, and ldap.

- [ ] **Step 7: Lint and commit**

```bash
cd images && ansible-lint ansible/ && shellcheck test/container/run.sh
cd .. && git add images/ansible images/test/container
git commit -m "feat(images): add repository and package installation roles

Installs percona-release with signature verification, enables the valkey-91
channel, and resolves the variant to its package set. The version assertion
fails the build when the requested release is not in the chosen channel."
```

---

## Task 4: Tuning and first-boot deployment roles

**Files:**
- Create: `images/ansible/roles/valkey-tuning/tasks/main.yml`
- Create: `images/ansible/roles/valkey-firstboot/tasks/main.yml`
- Create: `images/ansible/roles/valkey-firstboot/defaults/main.yml`
- Modify: `images/ansible/valkey-ami.yml`

**Interfaces:**
- Consumes: files from Tasks 1 and 2; `valkey_variant` from Task 3.
- Produces: an image where `/etc/valkey/default.conf` binds to loopback, enables protected
  mode, and includes `/etc/valkey/valkey-generated.conf` as its last directive. Task 6
  asserts each of these.

- [ ] **Step 1: Write the tuning role**

`images/ansible/roles/valkey-tuning/tasks/main.yml`:

```yaml
---
- name: Deploy the Valkey sysctl settings
  ansible.builtin.copy:
    src: 99-valkey.conf
    dest: /etc/sysctl.d/99-valkey.conf
    owner: root
    group: root
    mode: "0644"

- name: Deploy the transparent huge pages unit
  ansible.builtin.copy:
    src: valkey-thp.service
    dest: /etc/systemd/system/valkey-thp.service
    owner: root
    group: root
    mode: "0644"

- name: Create the valkey service drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/system/valkey@.service.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy the file descriptor limit drop-in
  ansible.builtin.copy:
    src: 10-limits.conf
    dest: /etc/systemd/system/valkey@.service.d/10-limits.conf
    owner: root
    group: root
    mode: "0644"

- name: Enable the transparent huge pages unit
  ansible.builtin.systemd:
    name: valkey-thp.service
    enabled: true
    daemon_reload: true
```

- [ ] **Step 2: Write the first-boot role**

`images/ansible/roles/valkey-firstboot/defaults/main.yml`:

```yaml
---
valkey_variant: slim
valkey_conf: /etc/valkey/default.conf
valkey_generated_conf: /etc/valkey/valkey-generated.conf
```

`images/ansible/roles/valkey-firstboot/tasks/main.yml`:

```yaml
---
- name: Install the first-boot script
  ansible.builtin.copy:
    src: valkey-firstboot.sh
    dest: /usr/local/sbin/valkey-firstboot
    owner: root
    group: root
    mode: "0750"

- name: Install the first-boot unit
  ansible.builtin.copy:
    src: valkey-firstboot.service
    dest: /etc/systemd/system/valkey-firstboot.service
    owner: root
    group: root
    mode: "0644"

- name: Set the variant the first-boot unit runs with
  ansible.builtin.lineinfile:
    path: /etc/systemd/system/valkey-firstboot.service
    regexp: '^Environment=VALKEY_VARIANT='
    line: "Environment=VALKEY_VARIANT={{ valkey_variant }}"

- name: Enable the first-boot unit
  ansible.builtin.systemd:
    name: valkey-firstboot.service
    enabled: true
    daemon_reload: true

- name: Bind Valkey to loopback only
  ansible.builtin.lineinfile:
    path: "{{ valkey_conf }}"
    regexp: '^#?\s*bind '
    line: 'bind 127.0.0.1 -::1'

- name: Enable protected mode
  ansible.builtin.lineinfile:
    path: "{{ valkey_conf }}"
    regexp: '^#?\s*protected-mode '
    line: 'protected-mode yes'

- name: Create an empty generated configuration
  # valkey-server treats an include of a missing file as fatal. The first-boot
  # unit fills this in before valkey@default.service starts, but the file must exist
  # from bake time so the include is always resolvable.
  ansible.builtin.copy:
    content: ""
    dest: "{{ valkey_generated_conf }}"
    owner: root
    group: valkey
    mode: "0640"
    force: false

- name: Include the generated configuration last
  # Later directives win, so this must remain the final line of default.conf
  # for the generated values to take effect.
  ansible.builtin.lineinfile:
    path: "{{ valkey_conf }}"
    line: "include {{ valkey_generated_conf }}"
    insertafter: EOF
    state: present

- name: Enable the default Valkey instance
  ansible.builtin.systemd:
    name: valkey@default.service
    enabled: true
```

- [ ] **Step 3: Add the roles to the playbook**

`images/ansible/valkey-ami.yml` becomes:

```yaml
---
- name: Build the Percona Valkey image
  hosts: all
  become: true
  gather_facts: true
  roles:
    - valkey-repo
    - valkey-install
    - valkey-tuning
    - valkey-firstboot
```

- [ ] **Step 4: Verify against the container**

Run: `cd images && make container VARIANT=bundle`
Expected: `failed=0`. The `systemd` tasks report a failure to contact the service manager
inside the container; that is expected and is covered on a real instance in Task 8. If the
run stops there, confirm the file-placement tasks above it all reported `ok` or `changed`.

- [ ] **Step 5: Lint and commit**

```bash
cd images && ansible-lint ansible/
cd .. && git add images/ansible
git commit -m "feat(images): deploy tuning and first-boot configuration

Locks the baseline to loopback with protected mode on, includes the
generated configuration as the final directive so per-instance values win,
and ships an empty placeholder so the include always resolves."
```

---

## Task 5: Cleanup role

**Files:**
- Create: `images/ansible/roles/cloud-cleanup/tasks/main.yml`
- Modify: `images/ansible/valkey-ami.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: an image with no host keys, authorized keys, logs, caches, shell history, or
  machine identity. Task 6 asserts each removal.

- [ ] **Step 1: Write the cleanup role**

`images/ansible/roles/cloud-cleanup/tasks/main.yml`:

```yaml
---
- name: Find SSH host keys
  ansible.builtin.find:
    paths: /etc/ssh
    patterns: 'ssh_host_*'
  register: ssh_host_keys

- name: Remove SSH host keys
  # Regenerated on first boot, so every instance gets a unique identity.
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ ssh_host_keys.files }}"
  loop_control:
    label: "{{ item.path }}"

- name: Find authorized_keys files
  ansible.builtin.find:
    paths:
      - /root
      - /home
    patterns: authorized_keys
    recurse: true
    hidden: true
  register: authorized_keys

- name: Remove authorized_keys files
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ authorized_keys.files }}"
  loop_control:
    label: "{{ item.path }}"

- name: Lock the root account
  ansible.builtin.user:
    name: root
    password_lock: true

- name: Clean the package manager cache
  ansible.builtin.command: dnf clean all
  changed_when: true

- name: Check whether cloud-init is present
  ansible.builtin.stat:
    path: /usr/bin/cloud-init
  register: cloud_init_bin

- name: Reset cloud-init state
  ansible.builtin.command: cloud-init clean --logs
  when: cloud_init_bin.stat.exists
  changed_when: true

- name: Find log files to truncate
  ansible.builtin.find:
    paths: /var/log
    patterns: '*.log,*.log.*,messages,secure,cron,dmesg'
    recurse: true
  register: log_files

- name: Truncate log files
  # Truncated rather than rewritten so ownership and permissions are preserved.
  ansible.builtin.command: "truncate -s 0 {{ item.path }}"
  loop: "{{ log_files.files }}"
  loop_control:
    label: "{{ item.path }}"
  changed_when: true

- name: Clear the systemd journal
  ansible.builtin.command: journalctl --rotate --vacuum-time=1s
  changed_when: true

- name: Find shell history files
  ansible.builtin.find:
    paths:
      - /root
      - /home
    patterns: '.*_history'
    recurse: true
    hidden: true
  register: history_files

- name: Remove shell history
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ history_files.files }}"
  loop_control:
    label: "{{ item.path }}"

- name: Clear the machine identity
  # Truncated rather than removed so systemd regenerates it at next boot.
  ansible.builtin.command: truncate -s 0 /etc/machine-id
  changed_when: true
```

- [ ] **Step 2: Add the role last in the playbook**

```yaml
  roles:
    - valkey-repo
    - valkey-install
    - valkey-tuning
    - valkey-firstboot
    - cloud-cleanup
```

- [ ] **Step 3: Verify against the container**

Run: `cd images && make container VARIANT=slim`
Expected: `failed=0`.

- [ ] **Step 4: Lint and commit**

```bash
cd images && ansible-lint ansible/
cd .. && git add images/ansible
git commit -m "feat(images): strip identity and secrets before bake

Removes host keys, authorized keys, history, logs, and machine identity so
no build artifact or credential survives into the published image."
```

---

## Task 6: In-image verification suites

These run inside the build instance and gate AMI creation.

**Files:**
- Create: `images/test/bats/install.bats`
- Create: `images/test/bats/config.bats`
- Create: `images/test/bats/hardening.bats`

**Interfaces:**
- Consumes: the fully provisioned instance from Tasks 3 through 5. Reads the environment
  variables `VALKEY_VARIANT` and `VALKEY_VERSION`, exported by the Packer provisioner in
  Task 7.
- Produces: a non-zero exit status on any failure, which aborts the Packer build.

- [ ] **Step 1: Write the install suite**

`images/test/bats/install.bats`:

```bash
#!/usr/bin/env bats

VARIANT="${VALKEY_VARIANT:-slim}"
VERSION="${VALKEY_VERSION:-9.1.1}"
MODULE_DIR=/usr/lib64/valkey/modules

@test 'the percona-valkey package is installed' {
    rpm -q percona-valkey
}

@test 'the installed version matches the requested version' {
    [ "$(rpm -q --queryformat '%{VERSION}' percona-valkey)" = "$VERSION" ]
}

@test 'the bundle package is installed only for the bundle variant' {
    if [ "$VARIANT" = "bundle" ]; then
        rpm -q percona-valkey-bundle
    else
        ! rpm -q percona-valkey-bundle
    fi
}

@test 'all four modules are present for the bundle variant' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no modules'
    rpm -q percona-valkey-json
    rpm -q percona-valkey-bloom
    rpm -q percona-valkey-search
    rpm -q percona-valkey-ldap
    [ "$(find "$MODULE_DIR" -maxdepth 1 -name '*.so' -type f | wc -l)" -ge 4 ]
}

@test 'no modules are present for the slim variant' {
    [ "$VARIANT" = "slim" ] || skip 'bundle variant ships modules'
    [ "$(find "$MODULE_DIR" -maxdepth 1 -name '*.so' -type f 2>/dev/null | wc -l)" -eq 0 ]
}

@test 'the server, sentinel, and tools binaries are present' {
    command -v valkey-server
    command -v valkey-sentinel
    command -v valkey-cli
    command -v valkey-benchmark
    command -v valkey-check-aof
    command -v valkey-check-rdb
}

@test 'the valkey user and group exist' {
    getent passwd valkey
    getent group valkey
}

@test 'the default valkey instance is enabled' {
    systemctl is-enabled valkey@default.service
}

@test 'the sentinel instance is not enabled' {
    [ -f /usr/lib/systemd/system/valkey-sentinel@.service ]
    ! systemctl is-enabled valkey-sentinel@default.service
}
```

- [ ] **Step 2: Write the configuration suite**

`images/test/bats/config.bats`:

```bash
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
```

- [ ] **Step 3: Write the hardening suite**

`images/test/bats/hardening.bats`:

```bash
#!/usr/bin/env bats

@test 'no authorized_keys files exist' {
    [ "$(find /root /home -name authorized_keys 2>/dev/null | wc -l)" -eq 0 ]
}

@test 'root login over ssh is disabled' {
    ! sshd -T 2>/dev/null | grep -qx 'permitrootlogin yes'
}

@test 'no ssh host keys are present' {
    [ "$(find /etc/ssh -name 'ssh_host_*' 2>/dev/null | wc -l)" -eq 0 ]
}

@test 'no account has a usable password' {
    ! awk -F: '$2 !~ /^[*!]/ && $2 != "" { print }' /etc/shadow | grep -q .
}

@test 'no shell history remains' {
    [ "$(find /root /home -name '.*_history' 2>/dev/null | wc -l)" -eq 0 ]
}

@test 'the machine id is cleared' {
    [ ! -s /etc/machine-id ]
}

@test 'no cached packages or repository metadata remain' {
    # dnf clean all deliberately keeps small bookkeeping files
    # (expired_repos.json, tempfiles.json, .gpgkeyschecked.yum) which hold no
    # package data. What must not survive the bake is downloaded rpms or the
    # repository metadata they were resolved from.
    [ "$(find /var/cache/dnf -name '*.rpm' 2>/dev/null | wc -l)" -eq 0 ]
    [ "$(find /var/cache/dnf \( -name '*.solv' -o -name '*.solvx' -o -name 'repomd.xml' \) \
        2>/dev/null | wc -l)" -eq 0 ]
}

@test 'no provisioning artifacts remain in tmp' {
    [ "$(find /tmp -maxdepth 1 -name 'percona-release*' 2>/dev/null | wc -l)" -eq 0 ]
    [ "$(find /tmp -maxdepth 1 -name '*.bats' 2>/dev/null | wc -l)" -eq 0 ]
}
```

The tmp assertion requires the Packer provisioner in Task 7 to remove the uploaded suites
after running them.

- [ ] **Step 4: Commit**

```bash
git add images/test/bats
git commit -m "test(images): add bake-time verification suites

Covers the installed package set per variant, the locked baseline
configuration, and the hardening requirements the Marketplace scan checks."
```

---

## Task 7: Packer template for all four images

**Files:**
- Create: `images/packer/variables.pkr.hcl`
- Create: `images/packer/valkey-ami.pkr.hcl`
- Create: `images/packer/release.pkvars.hcl`

**Interfaces:**
- Consumes: the playbook from Tasks 3 through 5 and the suites from Task 6.
- Produces: four AMIs named `percona-valkey-<version>-<variant>-<arch>-<YYYYMMDD>`,
  addressable to `-only` as `slim.amazon-ebs.x86_64`, `slim.amazon-ebs.arm64`,
  `bundle.amazon-ebs.x86_64`, `bundle.amazon-ebs.arm64`. Task 10 drives these from Jenkins.

- [ ] **Step 1: Write the variable declarations**

`images/packer/variables.pkr.hcl`:

```hcl
variable "valkey_version" {
  type    = string
  default = "9.1.1"
}

variable "repo_channel" {
  type    = string
  default = "release"

  validation {
    condition     = contains(["release", "testing", "experimental"], var.repo_channel)
    error_message = "repo_channel must be release, testing, or experimental."
  }
}

variable "build_region" {
  type    = string
  default = "us-east-1"
}

variable "ami_regions" {
  type    = list(string)
  default = []
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "instance_type_x86_64" {
  type    = string
  default = "c6i.large"
}

variable "instance_type_arm64" {
  type    = string
  default = "c6g.large"
}

variable "bats_version" {
  type    = string
  default = "1.11.0"
}
```

- [ ] **Step 2: Write the build template**

`images/packer/valkey-ami.pkr.hcl`:

```hcl
packer {
  required_version = ">= 1.9.0"

  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  build_date = formatdate("YYYYMMDD", timestamp())

  common_tags = {
    Product      = "Percona Valkey"
    ValkeyVersion = var.valkey_version
    RepoChannel  = var.repo_channel
    BuildDate    = formatdate("YYYYMMDD", timestamp())
  }
}

source "amazon-ebs" "slim_x86_64" {
  region        = var.build_region
  instance_type = var.instance_type_x86_64
  ssh_username  = "ec2-user"
  ami_name      = "percona-valkey-${var.valkey_version}-slim-x86_64-${local.build_date}"
  ami_description = "Percona Valkey ${var.valkey_version} on Amazon Linux 2023"
  ami_regions   = var.ami_regions
  encrypt_boot  = false

  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true
  ssh_clear_authorized_keys   = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags     = merge(local.common_tags, { Variant = "slim", Architecture = "x86_64" })
  run_tags = { Name = "packer-valkey-slim-x86_64" }
}

source "amazon-ebs" "slim_arm64" {
  region        = var.build_region
  instance_type = var.instance_type_arm64
  ssh_username  = "ec2-user"
  ami_name      = "percona-valkey-${var.valkey_version}-slim-arm64-${local.build_date}"
  ami_description = "Percona Valkey ${var.valkey_version} on Amazon Linux 2023"
  ami_regions   = var.ami_regions
  encrypt_boot  = false

  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true
  ssh_clear_authorized_keys   = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags     = merge(local.common_tags, { Variant = "slim", Architecture = "arm64" })
  run_tags = { Name = "packer-valkey-slim-arm64" }
}

source "amazon-ebs" "bundle_x86_64" {
  region        = var.build_region
  instance_type = var.instance_type_x86_64
  ssh_username  = "ec2-user"
  ami_name      = "percona-valkey-${var.valkey_version}-bundle-x86_64-${local.build_date}"
  ami_description = "Percona Valkey ${var.valkey_version} with modules on Amazon Linux 2023"
  ami_regions   = var.ami_regions
  encrypt_boot  = false

  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true
  ssh_clear_authorized_keys   = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags     = merge(local.common_tags, { Variant = "bundle", Architecture = "x86_64" })
  run_tags = { Name = "packer-valkey-bundle-x86_64" }
}

source "amazon-ebs" "bundle_arm64" {
  region        = var.build_region
  instance_type = var.instance_type_arm64
  ssh_username  = "ec2-user"
  ami_name      = "percona-valkey-${var.valkey_version}-bundle-arm64-${local.build_date}"
  ami_description = "Percona Valkey ${var.valkey_version} with modules on Amazon Linux 2023"
  ami_regions   = var.ami_regions
  encrypt_boot  = false

  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true
  ssh_clear_authorized_keys   = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags     = merge(local.common_tags, { Variant = "bundle", Architecture = "arm64" })
  run_tags = { Name = "packer-valkey-bundle-arm64" }
}

build {
  name    = "slim"
  sources = ["source.amazon-ebs.slim_x86_64", "source.amazon-ebs.slim_arm64"]

  provisioner "shell" {
    inline = [
      "sudo dnf -y install ansible-core tar gzip",
      # Amazon Linux 2023 ships no bats package. Install the pinned upstream
      # release under /opt so the whole tree can be removed before the snapshot.
      "curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${var.bats_version}.tar.gz -o /tmp/bats.tar.gz",
      "tar -xzf /tmp/bats.tar.gz -C /tmp",
      "sudo /tmp/bats-core-${var.bats_version}/install.sh /opt/bats",
      "rm -rf /tmp/bats.tar.gz /tmp/bats-core-${var.bats_version}",
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "${path.root}/../ansible/valkey-ami.yml"
    playbook_dir  = "${path.root}/../ansible"
    extra_arguments = [
      "-e", "valkey_variant=slim",
      "-e", "valkey_version=${var.valkey_version}",
      "-e", "valkey_repo_channel=${var.repo_channel}",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../test/bats"
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo VALKEY_VARIANT=slim VALKEY_VERSION=${var.valkey_version} /opt/bats/bin/bats /tmp/bats/*.bats",
      "rm -rf /tmp/bats",
      # Build-time only: neither belongs in a published image.
      "sudo rm -rf /opt/bats",
      "sudo dnf -y remove ansible-core",
      "sudo dnf clean all",
    ]
  }
}

build {
  name    = "bundle"
  sources = ["source.amazon-ebs.bundle_x86_64", "source.amazon-ebs.bundle_arm64"]

  provisioner "shell" {
    inline = [
      "sudo dnf -y install ansible-core tar gzip",
      # Amazon Linux 2023 ships no bats package. Install the pinned upstream
      # release under /opt so the whole tree can be removed before the snapshot.
      "curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${var.bats_version}.tar.gz -o /tmp/bats.tar.gz",
      "tar -xzf /tmp/bats.tar.gz -C /tmp",
      "sudo /tmp/bats-core-${var.bats_version}/install.sh /opt/bats",
      "rm -rf /tmp/bats.tar.gz /tmp/bats-core-${var.bats_version}",
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "${path.root}/../ansible/valkey-ami.yml"
    playbook_dir  = "${path.root}/../ansible"
    extra_arguments = [
      "-e", "valkey_variant=bundle",
      "-e", "valkey_version=${var.valkey_version}",
      "-e", "valkey_repo_channel=${var.repo_channel}",
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../test/bats"
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "sudo VALKEY_VARIANT=bundle VALKEY_VERSION=${var.valkey_version} /opt/bats/bin/bats /tmp/bats/*.bats",
      "rm -rf /tmp/bats",
      # Build-time only: neither belongs in a published image.
      "sudo rm -rf /opt/bats",
      "sudo dnf -y remove ansible-core",
      "sudo dnf clean all",
    ]
  }
}
```

The cleanup role runs as part of the playbook, before the suites upload. The final shell
provisioner removes the uploaded suites so the hardening assertion about `/tmp` holds for
the snapshot, then removes bats and `ansible-core`, which exist only to build and verify
the image. Because that removal happens after the suites run, their absence is asserted by
the post-launch smoke test in Task 8 rather than by `hardening.bats`.

- [ ] **Step 3: Write the variable files**

Build network identifiers are defaults on the `subnet_id` and `security_group_id`
variables in `variables.pkr.hcl`, set to the subnet and security group the existing
Percona AMI builds use. Packer derives the VPC from the subnet, so no `vpc_id` is
needed. Override with `-var` or `-var-file` to build in another account.

An auto-loaded `*.auto.pkvars.hcl` file was tried first and rejected: Packer 1.8.5
did not load it when the template was given as a directory, producing an unset
variable error. Defaults resolve identically on every version.

`images/packer/release.pkvars.hcl`:

```hcl
valkey_version = "9.1.1"
repo_channel   = "release"
build_region   = "us-east-1"

ami_regions = [
  "us-east-2",
  "us-west-1",
  "us-west-2",
  "eu-west-1",
  "eu-central-1",
  "ap-south-1",
  "ap-southeast-1",
  "ap-southeast-2",
  "ap-northeast-1",
  "sa-east-1",
]
```


- [ ] **Step 4: Initialize and validate**

Run:
```bash
cd images/packer && packer init . && packer fmt -check -diff . && packer validate .
```
Expected: `packer fmt` reports no changes, `packer validate` reports
`The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add images/packer
git commit -m "feat(images): add Packer template for all four AMIs

Four sources across variant and architecture, two build blocks sharing
provisioners, and a region copy list driven by variables. Build network
identifiers are confined to one file."
```

---

## Task 8: Smoke test and first end-to-end build

This closes milestone M1: one image proven all the way through.

**Files:**
- Create: `images/test/smoke/smoke.sh`
- Create: `images/README.md`

**Interfaces:**
- Consumes: an AMI ID produced by Task 7.
- Produces: `smoke.sh <ami-id> <region> <variant> [instance-type]`, exiting non-zero on any
  failed check. Task 10 calls it per image.

- [ ] **Step 1: Write the smoke test**

`images/test/smoke/smoke.sh`:

```bash
#!/bin/bash
set -euo pipefail

AMI_ID="${1:?usage: smoke.sh <ami-id> <region> <variant> [instance-type]}"
REGION="${2:?region required}"
VARIANT="${3:?variant required}"
INSTANCE_TYPE="${4:-c6i.large}"

SUBNET_ID="${SMOKE_SUBNET_ID:?SMOKE_SUBNET_ID must be set}"
SECURITY_GROUP_ID="${SMOKE_SECURITY_GROUP_ID:?SMOKE_SECURITY_GROUP_ID must be set}"
KEY_NAME="${SMOKE_KEY_NAME:?SMOKE_KEY_NAME must be set}"
KEY_FILE="${SMOKE_KEY_FILE:?SMOKE_KEY_FILE must be set}"

INSTANCE_ID=""
FAILURES=0

cleanup() {
    if [ -n "$INSTANCE_ID" ]; then
        aws ec2 terminate-instances --region "$REGION" \
            --instance-ids "$INSTANCE_ID" >/dev/null
    fi
}
trap cleanup EXIT

check() {
    local description="$1"
    shift
    if "$@"; then
        echo "ok       ${description}"
    else
        echo "FAIL     ${description}"
        FAILURES=$(( FAILURES + 1 ))
    fi
}

remote() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -i "$KEY_FILE" "ec2-user@${PUBLIC_IP}" "$@"
}

echo "Launching ${AMI_ID} in ${REGION}"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SUBNET_ID" --security-group-ids "$SECURITY_GROUP_ID" \
    --key-name "$KEY_NAME" --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=valkey-smoke}]' \
    --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

CONSOLE=$(aws ec2 get-console-output --region "$REGION" \
    --instance-id "$INSTANCE_ID" --output text)

check "console output contains the credential banner" \
    grep -q 'Percona Valkey' <<<"$CONSOLE"

PASSWORD=$(remote "sudo grep '^requirepass ' /etc/valkey/valkey-generated.conf | cut -d' ' -f2")

check "a password was generated" test -n "$PASSWORD"

PING=$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning PING")
check "the server answers PING" test "$PING" = "PONG"

MAXMEMORY=$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning CONFIG GET maxmemory | tail -1")
MEMTOTAL_KB=$(remote "awk '/^MemTotal:/ { print \$2 }' /proc/meminfo")
EXPECTED=$(( MEMTOTAL_KB * 1024 * 70 / 100 ))
TOLERANCE=$(( EXPECTED / 100 ))

within_tolerance() {
    [ "$1" -gt $(( EXPECTED - TOLERANCE )) ] && [ "$1" -lt $(( EXPECTED + TOLERANCE )) ]
}

check "maxmemory is approximately 70 percent of instance memory" \
    within_tolerance "$MAXMEMORY"

if [ "$VARIANT" = "bundle" ]; then
    MODULES=$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning MODULE LIST")
    for module in json bf search ldap; do
        check "module ${module} is loaded" grep -q "$module" <<<"$MODULES"
    done
else
    MODULES=$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning MODULE LIST")
    # Valkey always reports a built-in "lua" module, so the slim check asserts
    # the absence of the four packaged modules rather than an empty list.
    no_external_modules() {
        ! grep -qE '(^|[[:space:]])(json|bf|search|ldap)([[:space:]]|$)' <<<"$MODULES"
    }
    check "no packaged modules are loaded" no_external_modules
fi

port_closed() {
    ! timeout 5 bash -c "exec 3<>/dev/tcp/${PUBLIC_IP}/6379" 2>/dev/null
}

check "port 6379 is not reachable from outside the instance" port_closed

# Build tooling is removed after the bake-time suites run, so its absence can
# only be asserted here.
no_build_tooling() {
    remote "test ! -e /opt/bats && ! rpm -q ansible-core >/dev/null 2>&1"
}

check "build tooling is absent from the published image" no_build_tooling

echo "Rebooting to confirm the password is preserved"
remote "sudo systemctl reboot" || true
sleep 30
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PASSWORD_AFTER=$(remote "sudo grep '^requirepass ' /etc/valkey/valkey-generated.conf | cut -d' ' -f2")

check "the password is unchanged after reboot" test "$PASSWORD" = "$PASSWORD_AFTER"

SERVICE_STATE=$(remote "systemctl is-active valkey@default.service")
check "the service is running after reboot" test "$SERVICE_STATE" = "active"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "${FAILURES} check(s) failed"
    exit 1
fi
echo "all checks passed"
```

- [ ] **Step 2: Lint the smoke test**

Run: `cd images && shellcheck test/smoke/smoke.sh`
Expected: no output.

- [ ] **Step 3: Build the first image**

Run:
```bash
cd images/packer
packer build -only='slim.amazon-ebs.slim_x86_64' \
  -var-file=release.pkvars.hcl .
```
Expected: provisioning succeeds, all bats suites pass, and Packer prints an AMI ID.

If the bats stage fails, the AMI is not created. Read the failing assertion, fix the role
that produces it, and rerun. Do not weaken an assertion to make the build pass.

- [ ] **Step 4: Run the smoke test against the new AMI**

Run:
```bash
cd images
export SMOKE_SUBNET_ID=... SMOKE_SECURITY_GROUP_ID=... SMOKE_KEY_NAME=... SMOKE_KEY_FILE=...
chmod +x test/smoke/smoke.sh
test/smoke/smoke.sh <ami-id> us-east-1 slim c6i.large
```
Expected: `all checks passed`, and the instance is terminated by the exit trap.

- [ ] **Step 5: Write the README**

`images/README.md`:

```markdown
# Percona Valkey images

Packer and Ansible sources for the Percona Valkey AWS Marketplace AMIs.

Four images are produced from one template: the `slim` and `bundle` variants,
each on x86_64 and arm64, all based on Amazon Linux 2023.

| Variant | Packages | Modules |
|---|---|---|
| `slim` | `percona-valkey` | none |
| `bundle` | `percona-valkey-bundle` | json, bloom, search, ldap, loaded automatically |

## Prerequisites

Packer 1.9 or newer, Ansible, bats, shellcheck, and AWS credentials with
permission to launch instances, create AMIs, and copy them between regions.

The build network defaults to the subnet and security group shared with the
other Percona AMI builds. Override `subnet_id` and `security_group_id` to build
in a different account.

## Local checks

    make lint       # shellcheck, packer fmt, ansible-lint
    make unit       # first-boot script unit tests, no AWS required
    make container  # apply the playbook in an Amazon Linux 2023 container

## Building

    cd packer
    packer init .
    packer build -var-file=release.pkvars.hcl .

Build one image with `-only`, for example
`-only='slim.amazon-ebs.slim_x86_64'`.

## Verifying a built image

    export SMOKE_SUBNET_ID=... SMOKE_SECURITY_GROUP_ID=...
    export SMOKE_KEY_NAME=... SMOKE_KEY_FILE=...
    test/smoke/smoke.sh <ami-id> <region> <variant>

## First boot

Each instance generates its own Valkey password on first boot. It is written to
the system log, visible with `aws ec2 get-console-output`, and to the message of
the day shown when logging in over SSH.

Valkey listens on localhost only. Review `/etc/valkey/default.conf` and adjust the
security group before exposing the service.
```

- [ ] **Step 6: Commit**

```bash
git add images/test/smoke images/README.md
git commit -m "feat(images): add post-launch smoke test and build documentation

Verifies credential generation, memory sizing, module loading, network
exposure, and that a reboot preserves the generated password."
```

---

## Task 9: Build the remaining three images

**Files:** none created. This task exercises Tasks 3 through 8 across the full matrix.

**Interfaces:**
- Consumes: the template from Task 7 and the smoke test from Task 8.
- Produces: four verified AMIs in the build region, copied to the region list.

- [ ] **Step 1: Build the bundle x86_64 image**

Run:
```bash
cd images/packer
packer build -only='bundle.amazon-ebs.bundle_x86_64' -var-file=release.pkvars.hcl .
```
Expected: the bats install suite confirms four modules; the build succeeds.

- [ ] **Step 2: Smoke test the bundle image**

Run: `cd images && test/smoke/smoke.sh <ami-id> us-east-1 bundle c6i.large`
Expected: `all checks passed`, including all four module assertions.

- [ ] **Step 3: Build both arm64 images**

Run:
```bash
cd images/packer
packer build -only='slim.amazon-ebs.slim_arm64,bundle.amazon-ebs.bundle_arm64' \
  -var-file=release.pkvars.hcl .
```
Expected: both succeed. Module objects resolve under `/usr/lib64/valkey/modules` on arm64
exactly as on x86_64.

- [ ] **Step 4: Smoke test both arm64 images**

Run:
```bash
cd images
test/smoke/smoke.sh <slim-arm64-ami-id> us-east-1 slim c6g.large
test/smoke/smoke.sh <bundle-arm64-ami-id> us-east-1 bundle c6g.large
```
Expected: `all checks passed` for both.

- [ ] **Step 5: Confirm the region copies completed**

Run:
```bash
aws ec2 describe-images --owners self --region eu-west-1 \
  --filters "Name=name,Values=percona-valkey-9.1.1-*" \
  --query 'Images[].[Name,ImageId,State]' --output table
```
Expected: four images in `available` state in each region from `ami_regions`.

- [ ] **Step 6: Record the results**

Create `images/BUILDS.md` listing, for each of the four images: variant, architecture, AMI
ID in the build region, build date, and smoke test outcome. Commit it.

```bash
git add images/BUILDS.md
git commit -m "docs(images): record the first full build matrix results"
```

---

## Task 10: Jenkins pipeline

**Files:**
- Create: `rel/jenkins/valkey-ami.groovy` and `rel/jenkins/valkey-ami.yml` in
  `Percona-Lab/jenkins-pipelines` on the `hetzner` branch

**Interfaces:**
- Consumes: everything above.
- Produces: a parameterized pipeline building the matrix, copying to regions, and running
  the smoke test per image.

- [x] **Step 1: Write the pipeline**

Implemented as a Job Builder pair in `Percona-Lab/jenkins-pipelines` on the `hetzner`
branch: `rel/jenkins/valkey-ami.groovy` and `rel/jenkins/valkey-ami.yml`. It follows the conventions of the existing
Percona AMI job (`Percona-Lab/jenkins-pipelines`, `ps/jenkins/ps80-ami.groovy`):

| Convention | Value |
|---|---|
| Agent label | `min-ol-9-x64` |
| AWS credentials | `re-cd-aws` via `AmazonWebServicesCredentialsBinding` |
| Region | `us-east-1` |
| Packer | installed to `~/bin` by `make deps`, run with `-color=false`, output teed to a log |
| AMI id | extracted from the log, stashed and archived per variant and architecture |
| Notifications | `#releases-ci`, colour-coded start, success, and failure |
| Options | `skipDefaultCheckout()`, `disableConcurrentBuilds()` |

It differs from the PS80 job in building a matrix of four images rather than one, so each
cell writes `build-<variant>-<arch>.log` and `ami-<variant>-<arch>.txt`, and it adds a
per-image smoke stage gated on the `RUN_SMOKE` parameter.

- [ ] **Step 2: Validate the pipeline syntax**

Run the Jenkins linter against the controller:
```bash
curl -X POST -F "jenkinsfile=<rel/jenkins/valkey-ami.groovy" \
  "${JENKINS_URL}/pipeline-model-converter/validate"
```
Expected: `Jenkinsfile successfully validated.`

The job definition is applied with Job Builder:

```bash
jenkins-jobs update rel/jenkins/valkey-ami.yml
```

- [ ] **Step 3: Run the pipeline once end to end**

Trigger with the defaults. Expected: four builds succeed, four smoke tests pass, logs
archived.

- [ ] **Step 4: Commit**

```bash
git add rel/jenkins/valkey-ami.groovy rel/jenkins/valkey-ami.yml
git commit -m "ci(images): add image build pipeline

Matrix over variant and architecture with linting and unit tests as entry
gates, and a smoke test per image before the build is considered good."
```

---

## Task 11: Marketplace preparation

**Files:**
- Create: `images/MARKETPLACE.md`

**Interfaces:**
- Consumes: the four verified AMIs from Task 9.
- Produces: the content and checklist needed for a manual Marketplace submission.

- [ ] **Step 1: Run the AWS self-service scan**

Share each AMI with the AWS Marketplace scanning account and start a scan through the
Marketplace Management Portal. Record the result for each of the four images.

- [ ] **Step 2: Write the submission document**

`images/MARKETPLACE.md` must contain:

- The four AMI IDs, their variants, architectures, and build date.
- Product title, short description, and long description.
- The instance types recommended for each variant, and the minimum memory for `bundle`
  given the search module's footprint.
- Security group guidance: port 22 for administration, port 6379 only from trusted CIDRs,
  and a statement that Valkey listens on localhost until reconfigured.
- Usage instructions covering how to retrieve the generated password from the system log
  and from the message of the day, and how to change it.
- The scan results from Step 1.
- A statement that the images are unencrypted, as required for AMI listings.
- Version release notes for Valkey 9.1.1 and the bundled module versions: json 1.0.2,
  bloom 1.0.1, search 1.2.0, ldap 1.1.1.

- [ ] **Step 3: Verify against the hardening requirements**

Confirm each item in the spec's security section has a passing bats assertion by running
the suites against a launched instance of each published AMI:

```bash
cd images
scp -i "$SMOKE_KEY_FILE" -r test/bats ec2-user@<instance-ip>:/tmp/
ssh -i "$SMOKE_KEY_FILE" ec2-user@<instance-ip> \
  "sudo VALKEY_VARIANT=<variant> VALKEY_VERSION=9.1.1 bats /tmp/bats/hardening.bats"
```

Expected: all assertions pass except the first-boot marker check in `config.bats`, which is
expected to fail on a booted instance because the marker now exists. Run only
`hardening.bats` here for that reason.

- [ ] **Step 4: Commit**

```bash
git add images/MARKETPLACE.md
git commit -m "docs(images): add Marketplace submission checklist and listing content"
```

- [ ] **Step 5: Open the pull request**

```bash
git push -u origin feat/valkey-ami
gh pr create --base main \
  --title "Percona Valkey AWS Marketplace AMIs" \
  --body "$(cat <<'EOF'
Adds `images/`, producing four AWS Marketplace AMIs for Percona Valkey 9.1.1
on Amazon Linux 2023: `slim` and `bundle` variants across x86_64 and arm64.

Packages install from the `valkey-91` release channel. Per-instance credentials
and memory limits are applied by a systemd unit ordered before `valkey@default.service`,
so the server never starts unconfigured. A bats suite gates AMI creation and a
smoke test against a launched instance gates release.

Design: `docs/specs/2026-08-08-valkey-ami-design.md`
Plan: `docs/plans/2026-08-08-valkey-ami.md`

## Test plan

- [ ] `make lint` passes
- [ ] `make unit` passes
- [ ] `make container` passes for both variants
- [ ] All four images build with the bats suites passing
- [ ] Smoke test passes for all four images
- [ ] Region copies complete
- [ ] AWS self-service scan passes for all four images
EOF
)"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: package mapping to Task 3; first-boot
sequence and generated directives to Tasks 1 and 4; repository configuration to Task 3;
baseline configuration to Tasks 2 and 4; security and Marketplace requirements to Tasks 5,
6, and 11; testing to Tasks 6 and 8; failure handling to the gates in Tasks 7 and 8; naming
and versioning to Task 7; build network to Task 7; milestones M0 through M4 to Tasks 1
through 11.

**Interface consistency.** The environment variable names in the Task 1 script match the
Task 1 tests, the Task 2 unit, the Task 4 role, and the Task 7 provisioner:
`VALKEY_FIRSTBOOT_ROOT`, `VALKEY_FIRSTBOOT_MEMINFO`, `VALKEY_FIRSTBOOT_MODULE_DIR`,
`VALKEY_FIRSTBOOT_CONSOLE`, `VALKEY_VARIANT`. Path constants
`/etc/valkey/valkey-generated.conf`, `/etc/valkey/.firstboot-done`, and
`/usr/lib64/valkey/modules` are identical in Tasks 1, 4, 6, and 8. Source block names in
Task 7 match the `-only` selectors in Tasks 8, 9, and 10.

**Known gap.** The spec's assumption about 9.1.1 being promoted to the `release` channel is
verified for the first time in Task 3 Step 5. If it has not been promoted, that step is the
signal, and `repo_channel` allows proceeding against `testing` until it is.
