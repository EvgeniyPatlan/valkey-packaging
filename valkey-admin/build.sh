#!/usr/bin/env bash
set -euo pipefail
PACKAGING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PACKAGING_ROOT/lib/assert.sh"

usage() {
  cat <<USAGE
usage: build.sh list                  print the target table
       build.sh image <target>        build the per-distro build image
       build.sh test                  run the packaging test suite
       build.sh <target> [arch]       build packages for <target>
USAGE
}

cmd_list() { grep -v '^#' "$PACKAGING_ROOT/targets.conf" | grep -v '^[[:space:]]*$'; }

cmd_test() {
  local rc=0 checked=0
  shopt -s nullglob
  for t in "$PACKAGING_ROOT"/tests/test-*.sh; do
    echo "== $(basename "$t")"
    bash "$t" || rc=1
    checked=$((checked + 1))
  done
  shopt -u nullglob
  # Today this fails loudly on its own -- nullglob is not set process-wide,
  # so an empty match leaves the literal "tests/test-*.sh" glob in $t and
  # bash fails to execute it. But that protection is incidental, not
  # structural: test-lint.sh already sets nullglob locally, and if that ever
  # migrates into this shared helper, an empty match here would iterate zero
  # times and cmd_test would exit 0 having run nothing. Make "no test files
  # were found" a hard failure explicitly, the same way every test-*.sh
  # itself guards its own discovery loops.
  assert_checked "$checked" "packaging test files run"

  # test-rpm-install.sh and test-deb-install.sh default to installing a
  # single target apiece (el9, debian12) -- the loop above already ran each
  # once, with those defaults. Six of the nine built targets were otherwise
  # never installed anywhere. Two more RPM targets carry install-time
  # behavior no other target exercises: el8 is the only target whose %pre
  # takes the useradd branch (it has no systemd-rpm-macros package to
  # provide %sysusers_create_compat), and amazon2023 is the only target
  # where the "or nodejs22" half of the dependency is load-bearing (it
  # ships no unversioned "nodejs" package at all). Drive both explicitly
  # through the TEST_TARGET/TEST_IMAGE hooks test-rpm-install.sh already
  # reads, using the same targets.conf every other test reads, rather than
  # installing a full nine-target sweep on every default run.
  #
  # el10 and every DEB target besides debian12 remain reachable the same
  # way and are not part of this default: e.g.
  #   TEST_TARGET=el10 TEST_IMAGE="rockylinux/rockylinux:10" \
  #     bash tests/test-rpm-install.sh
  #   TEST_TARGET=ubuntu2204 TEST_IMAGE="ubuntu:22.04" \
  #     bash tests/test-deb-install.sh
  local extra_rpm_target image
  for extra_rpm_target in el8 amazon2023; do
    image="$(targets_field "$extra_rpm_target" image)"
    echo "== test-rpm-install.sh ($extra_rpm_target)"
    TEST_TARGET="$extra_rpm_target" TEST_IMAGE="$image" \
      bash "$PACKAGING_ROOT/tests/test-rpm-install.sh" || rc=1
  done

  return $rc
}

build_image() {
  local target="$1"
  local dockerfile="$PACKAGING_ROOT/docker/Dockerfile.$target"
  [ -f "$dockerfile" ] || { echo "no Dockerfile for target: $target" >&2; return 2; }
  docker build -t "valkey-admin-pkg:$target" -f "$dockerfile" "$PACKAGING_ROOT/docker"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|-h|--help) usage; exit 0 ;;
    list)  cmd_list ;;
    test)  cmd_test ;;
    image) build_image "${2:?target required}" ;;
    *)
      local family
      family="$(targets_field "$cmd" family)"
      [ -n "$family" ] || { echo "unknown target: $cmd" >&2; usage >&2; exit 2; }
      case "$family" in
        rpm) "$PACKAGING_ROOT/rpm/build-rpm.sh" "$cmd" "${2:-}" ;;
        deb) "$PACKAGING_ROOT/build-deb.sh" "$cmd" "${2:-}" ;;
      esac
      ;;
  esac
}
main "$@"
