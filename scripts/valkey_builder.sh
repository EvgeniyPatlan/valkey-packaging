#!/usr/bin/env bash
#
# valkey_builder.sh — Build script for Valkey packages (RPM, DEB, source tarballs)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PRODUCT="valkey"
readonly PACKAGE_NAME="percona-valkey"
readonly DEFAULT_VERSION="9.1.0"
readonly DEFAULT_RELEASE="1"
# Upstream 9.1.0 is not yet tagged — build from the 9.1 branch.
readonly DEFAULT_BRANCH="9.1"
readonly DEFAULT_REPO="https://github.com/valkey-io/valkey.git"

# valkey-json module packaging (separate upstream source + version)
readonly JSON_PACKAGE_NAME="percona-valkey-json"
readonly DEFAULT_JSON_REPO="https://github.com/valkey-io/valkey-json.git"
readonly DEFAULT_JSON_VERSION="1.0.2"
# RapidJSON is vendored into the source tarball so the module builds offline
# (upstream CMake otherwise FetchContent-clones it from GitHub at build time).
readonly RAPIDJSON_REPO="https://github.com/Tencent/rapidjson.git"
readonly RAPIDJSON_COMMIT="ebd87cb468fb4cb060b37e579718c4a4125416c1"

# valkey-bloom module packaging (Rust; separate upstream source + version)
readonly BLOOM_PACKAGE_NAME="percona-valkey-bloom"
readonly DEFAULT_BLOOM_REPO="https://github.com/valkey-io/valkey-bloom.git"
readonly DEFAULT_BLOOM_VERSION="1.0.1"

# valkey-search module packaging (C++20; deps gRPC/Protobuf/Abseil/ICU built
# from source at package-build time; separate upstream source + version)
readonly SEARCH_PACKAGE_NAME="percona-valkey-search"
readonly DEFAULT_SEARCH_REPO="https://github.com/valkey-io/valkey-search.git"
readonly DEFAULT_SEARCH_VERSION="1.2.0"

# valkey-bundle meta-package: depends on the server + every module, ships no
# payload of its own. No upstream source to compile — the "source" is a small
# tarball (README + LICENSE) assembled from this repo's bundle/ dir.
readonly BUNDLE_PACKAGE_NAME="percona-valkey-bundle"
readonly DEFAULT_BUNDLE_VERSION="9.1.0"

# Absolute path to the directory containing this script
BUILDER_SCRIPT_DIR="$(dirname "$(readlink -e "${0}")")"
readonly BUILDER_SCRIPT_DIR

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Script exited with code $rc"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given:
        --builddir=DIR                  Absolute path to the dir where all actions will be performed
        --get_sources                   Source will be downloaded from github
        --build_src_rpm                 If it is set - src rpm will be built
        --build_src_deb                 If it is set - source deb package will be built
        --build_rpm                     If it is set - rpm will be built
        --build_deb                     If it is set - deb will be built
        --install_deps                  Install build dependencies (root privileges are required)
        --branch=BRANCH                 Branch for build (default: ${DEFAULT_BRANCH})
        --repo=URL                      Repo for build (default: ${DEFAULT_REPO})
        --version=VER                   Version string (default: ${DEFAULT_VERSION})
        --release=REL                   Release number (default: ${DEFAULT_RELEASE})
        --use_local_packaging_script    Use local packaging scripts (located in ${BUILDER_SCRIPT_DIR}/../{debian,rpm})
        --json_deps                     Install valkey-json build deps (Percona repo, percona-valkey-dev(el), cmake, g++)
        --get_json_sources              Fetch valkey-json + vendor RapidJSON into an offline tarball
        --build_json_src_rpm            Build the percona-valkey-json source RPM
        --build_json_rpm                Build the percona-valkey-json binary RPM
        --build_json_src_deb            Build the percona-valkey-json source DEB
        --build_json_deb                Build the percona-valkey-json binary DEB
        --json_version=VER              valkey-json version (default: ${DEFAULT_JSON_VERSION})
        --json_branch=REF               valkey-json git ref (default: same as --json_version)
        --json_repo=URL                 valkey-json source repo (default: ${DEFAULT_JSON_REPO})
        --bloom_deps                    Install valkey-bloom build deps (rustup, clang, build tools)
        --get_bloom_sources             Fetch valkey-bloom + vendor cargo deps into an offline tarball
        --build_bloom_src_rpm           Build the percona-valkey-bloom source RPM
        --build_bloom_rpm               Build the percona-valkey-bloom binary RPM
        --build_bloom_src_deb           Build the percona-valkey-bloom source DEB
        --build_bloom_deb               Build the percona-valkey-bloom binary DEB
        --bloom_version=VER             valkey-bloom version (default: ${DEFAULT_BLOOM_VERSION})
        --bloom_branch=REF              valkey-bloom git ref (default: same as --bloom_version)
        --bloom_repo=URL                valkey-bloom source repo (default: ${DEFAULT_BLOOM_REPO})
        --search_deps                   Install valkey-search build deps (g++>=12 toolchain, cmake, make, ...)
        --get_search_sources            Fetch valkey-search into a source tarball
        --build_search_src_rpm          Build the percona-valkey-search source RPM
        --build_search_rpm              Build the percona-valkey-search binary RPM
        --build_search_src_deb          Build the percona-valkey-search source DEB
        --build_search_deb              Build the percona-valkey-search binary DEB
        --search_version=VER            valkey-search version (default: ${DEFAULT_SEARCH_VERSION})
        --search_branch=REF             valkey-search git ref (default: same as --search_version)
        --bundle_deps                   Install valkey-bundle packaging tools (rpm-build / debhelper)
        --get_bundle_sources            Assemble the percona-valkey-bundle meta-package source tarball
        --build_bundle_src_rpm          Build the percona-valkey-bundle source RPM
        --build_bundle_rpm              Build the percona-valkey-bundle binary RPM (per-arch meta)
        --build_bundle_src_deb          Build the percona-valkey-bundle source DEB
        --build_bundle_deb              Build the percona-valkey-bundle binary DEB (per-arch meta)
        --bundle_version=VER            valkey-bundle version (default: ${DEFAULT_BUNDLE_VERSION})
        --search_repo=URL               valkey-search source repo (default: ${DEFAULT_SEARCH_REPO})
        --help                          Print usage
Example: $0 --builddir=/tmp/BUILD --get_sources --build_src_rpm --build_rpm
         $0 --builddir=/tmp/BUILD --get_json_sources --build_json_src_deb --build_json_deb
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --builddir=*)                WORKDIR="${arg#*=}" ;;
            --build_src_rpm=*|--build_src_rpm) SRPM=1 ;;
            --build_src_deb=*|--build_src_deb) SDEB=1 ;;
            --build_rpm=*|--build_rpm)   RPM=1 ;;
            --build_deb=*|--build_deb)   DEB=1 ;;
            --get_sources=*|--get_sources) SOURCE=1 ;;
            --branch=*)                  BRANCH="${arg#*=}" ;;
            --repo=*)                    REPO="${arg#*=}" ;;
            --version=*)                 VERSION="${arg#*=}" ;;
            --release=*)                 RELEASE="${arg#*=}" ;;
            --install_deps=*|--install_deps) INSTALL=1 ;;
            --use_local_packaging_script=*|--use_local_packaging_script) LOCAL_BUILD=1 ;;
            --json_deps=*|--json_deps)   JSON_DEPS=1 ;;
            --get_json_sources=*|--get_json_sources) JSON_SOURCE=1 ;;
            --build_json_src_rpm=*|--build_json_src_rpm) JSON_SRPM=1 ;;
            --build_json_rpm=*|--build_json_rpm)     JSON_RPM=1 ;;
            --build_json_src_deb=*|--build_json_src_deb) JSON_SDEB=1 ;;
            --build_json_deb=*|--build_json_deb)     JSON_DEB=1 ;;
            --json_version=*)            JSON_VERSION="${arg#*=}" ;;
            --json_branch=*)             JSON_BRANCH="${arg#*=}" ;;
            --json_repo=*)               JSON_REPO="${arg#*=}" ;;
            --bloom_deps=*|--bloom_deps) BLOOM_DEPS=1 ;;
            --get_bloom_sources=*|--get_bloom_sources) BLOOM_SOURCE=1 ;;
            --build_bloom_src_rpm=*|--build_bloom_src_rpm) BLOOM_SRPM=1 ;;
            --build_bloom_rpm=*|--build_bloom_rpm)   BLOOM_RPM=1 ;;
            --build_bloom_src_deb=*|--build_bloom_src_deb) BLOOM_SDEB=1 ;;
            --build_bloom_deb=*|--build_bloom_deb)   BLOOM_DEB=1 ;;
            --bloom_version=*)           BLOOM_VERSION="${arg#*=}" ;;
            --bloom_branch=*)            BLOOM_BRANCH="${arg#*=}" ;;
            --bloom_repo=*)              BLOOM_REPO="${arg#*=}" ;;
            --search_deps=*|--search_deps) SEARCH_DEPS=1 ;;
            --get_search_sources=*|--get_search_sources) SEARCH_SOURCE=1 ;;
            --build_search_src_rpm=*|--build_search_src_rpm) SEARCH_SRPM=1 ;;
            --build_search_rpm=*|--build_search_rpm) SEARCH_RPM=1 ;;
            --build_search_src_deb=*|--build_search_src_deb) SEARCH_SDEB=1 ;;
            --build_search_deb=*|--build_search_deb) SEARCH_DEB=1 ;;
            --search_version=*)          SEARCH_VERSION="${arg#*=}" ;;
            --search_branch=*)           SEARCH_BRANCH="${arg#*=}" ;;
            --search_repo=*)             SEARCH_REPO="${arg#*=}" ;;
            --bundle_deps=*|--bundle_deps) BUNDLE_DEPS=1 ;;
            --get_bundle_sources=*|--get_bundle_sources) BUNDLE_SOURCE=1 ;;
            --build_bundle_src_rpm=*|--build_bundle_src_rpm) BUNDLE_SRPM=1 ;;
            --build_bundle_rpm=*|--build_bundle_rpm) BUNDLE_RPM=1 ;;
            --build_bundle_src_deb=*|--build_bundle_src_deb) BUNDLE_SDEB=1 ;;
            --build_bundle_deb=*|--build_bundle_deb) BUNDLE_DEB=1 ;;
            --bundle_version=*)          BUNDLE_VERSION="${arg#*=}" ;;
            --help)                      usage ;;
            *)                           die "Unknown option: $arg" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# find_and_copy_artifact SEARCH_SUBDIR GLOB_PATTERN
#   Looks for an artifact matching GLOB_PATTERN in $WORKDIR/SEARCH_SUBDIR first,
#   then falls back to $CURDIR/SEARCH_SUBDIR.  Copies the newest match into $WORKDIR.
#   Sets the variable FOUND_FILE to the basename of the found file.
find_and_copy_artifact() {
    local search_subdir="$1"
    local glob_pattern="$2"
    local found

    found="$(find "$WORKDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    found="$(find "$CURDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    log_error "No artifact matching '$glob_pattern' found in $search_subdir"
    return 1
}

# copy_artifacts DEST_SUBDIR FILE...
#   Copies the given files into both $WORKDIR/DEST_SUBDIR and $CURDIR/DEST_SUBDIR.
#   Glob expansion happens at the call site, so pass unquoted globs as arguments.
copy_artifacts() {
    local dest_subdir="$1"
    shift

    mkdir -p "$WORKDIR/$dest_subdir"
    mkdir -p "$CURDIR/$dest_subdir"
    cp "$@" "$WORKDIR/$dest_subdir/"
    cp "$@" "$CURDIR/$dest_subdir/"
}

# ---------------------------------------------------------------------------
# SBOM generation (Syft)
# ---------------------------------------------------------------------------
SYFT_BIN=""

# install_syft — make Syft available, preferring an already-installed binary
# and otherwise downloading it into $WORKDIR/.sbom-tools/bin. Non-fatal: on
# failure it logs a warning and leaves SYFT_BIN empty so the package build is
# not aborted just because an SBOM could not be produced.
install_syft() {
    if [[ -n "$SYFT_BIN" && -x "$SYFT_BIN" ]]; then
        return 0
    fi
    if command -v syft &>/dev/null; then
        SYFT_BIN="$(command -v syft)"
        return 0
    fi

    local bindir="${WORKDIR}/.sbom-tools/bin"
    mkdir -p "$bindir"
    log_info "Installing Syft for SBOM generation..."
    if command -v curl &>/dev/null; then
        curl -sSfL https://get.anchore.io/syft | sh -s -- -b "$bindir" >/dev/null 2>&1 || true
    elif command -v wget &>/dev/null; then
        wget -qO- https://get.anchore.io/syft | sh -s -- -b "$bindir" >/dev/null 2>&1 || true
    fi

    if [[ -x "${bindir}/syft" ]]; then
        SYFT_BIN="${bindir}/syft"
    else
        log_warn "Could not install Syft; SBOM will not be generated"
        SYFT_BIN=""
    fi
}

# generate_sbom_files SCAN_DIR OUT_SPDX OUT_CDX
#   Generate SPDX-JSON and CycloneDX-JSON SBOMs for SCAN_DIR, excluding the
#   packaging and VCS directories so the inventory reflects upstream Valkey
#   components (including the vendored deps). Best-effort: if Syft is
#   unavailable or fails, writes minimal placeholder documents so downstream
#   packaging always finds the files and the build does not abort.
generate_sbom_files() {
    local scan_dir="$1"
    local out_spdx="$2"
    local out_cdx="$3"

    install_syft
    if [[ -n "$SYFT_BIN" ]]; then
        log_info "Generating SBOM (SPDX + CycloneDX) from ${scan_dir} ..."
        if "$SYFT_BIN" scan "dir:${scan_dir}" \
            --source-name "$PACKAGE_NAME" --source-version "$VERSION" \
            --exclude './debian' --exclude './rpm' --exclude './.git' \
            -o "spdx-json=${out_spdx}" \
            -o "cyclonedx-json=${out_cdx}"; then
            return 0
        fi
        log_warn "Syft scan failed; writing placeholder SBOMs"
    else
        log_warn "Syft unavailable; writing placeholder SBOMs"
    fi

    printf '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"%s-%s","packages":[]}\n' \
        "$PACKAGE_NAME" "$VERSION" > "$out_spdx"
    printf '{"bomFormat":"CycloneDX","specVersion":"1.5","metadata":{"component":{"name":"%s","version":"%s","type":"application"}},"components":[]}\n' \
        "$PACKAGE_NAME" "$VERSION" > "$out_cdx"
}

# ---------------------------------------------------------------------------
# check_workdir
# ---------------------------------------------------------------------------
check_workdir() {
    if [[ -z "$WORKDIR" ]]; then
        die "--builddir is required"
    fi
    if [[ "$WORKDIR" == "$CURDIR" ]]; then
        die "Current directory cannot be used for building!"
    fi
    if [[ ! -d "$WORKDIR" ]]; then
        die "$WORKDIR is not a directory."
    fi
}

# ---------------------------------------------------------------------------
# get_sources
# ---------------------------------------------------------------------------
get_sources() {
    if [[ "$SOURCE" -eq 0 ]]; then
        log_info "Sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local product_full="${PRODUCT}-${VERSION}"

    cat > valkey.properties <<EOF
PRODUCT=${PRODUCT}
PRODUCT_FULL=${product_full}
VERSION=${VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
EOF

    log_info "Cloning $REPO ..."
    if ! git clone "$REPO" "$product_full"; then
        die "Failed to clone repo from $REPO. Please retry."
    fi

    cd "$product_full" || die "Cannot cd to $product_full"

    if [[ -n "$BRANCH" ]]; then
        git reset --hard
        git clean -xdf
        git checkout "$BRANCH"
    fi

    local revision
    revision="$(git rev-parse --short HEAD)"
    echo "REVISION=${revision}" >> "${WORKDIR}/valkey.properties"

    if [[ "$LOCAL_BUILD" -eq 0 ]]; then
        log_info "Downloading packaging scripts from github"
        git clone https://github.com/EvgeniyPatlan/valkey-packaging.git packaging

        # Check out the packaging branch matching the package version, NOT the
        # upstream Valkey branch. The packaging repo and the upstream Valkey
        # repo have different branch names: upstream uses release branches
        # like "9.1" while the packaging repo uses "9.1.0" (the full version).
        # Using $BRANCH for both was a long-standing bug — when --branch=9.1
        # was passed, this would try to git checkout 9.1 in the packaging
        # repo (which has no such branch) and either abort the build or
        # silently leave the clone on the default branch with a stale spec.
        local packaging_branch="${PACKAGING_BRANCH:-$VERSION}"
        if [[ -n "$packaging_branch" ]]; then
            cd packaging || die "Cannot cd to packaging"
            git reset --hard
            git clean -xdf
            if ! git checkout "$packaging_branch"; then
                log_warn "Packaging branch '$packaging_branch' not found; staying on default branch"
            fi
            cd ..
        fi

        mv packaging/debian ./
        mv packaging/rpm ./
    else
        log_info "Using local packaging scripts"
        cp -r "${BUILDER_SCRIPT_DIR}/../debian" ./
        cp -r "${BUILDER_SCRIPT_DIR}/../rpm" ./
    fi

    # Generate a real SBOM (SPDX + CycloneDX) of the upstream source tree and
    # bake it into the source tree (debian/ and rpm/) so it travels in the
    # tarball / source package and is embedded into the built RPM/DEB packages.
    generate_sbom_files "." "./debian/valkey.spdx.json" "./debian/valkey.cdx.json"
    cp -f ./debian/valkey.spdx.json ./debian/valkey.cdx.json ./rpm/
    copy_artifacts "sbom" ./debian/valkey.spdx.json ./debian/valkey.cdx.json

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    tar --owner=0 --group=0 --exclude=.git -czf "${product_full}.tar.gz" "$product_full"

    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${product_full}/${BRANCH}/${revision}/${BUILD_ID:-}" >> valkey.properties

    copy_artifacts "source_tarball" "${product_full}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_json_sources — fetch valkey-json, vendor RapidJSON, emit offline tarball
# ---------------------------------------------------------------------------
get_json_sources() {
    if [[ "$JSON_SOURCE" -eq 0 ]]; then
        log_info "valkey-json sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}-${JSON_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-json ${JSON_BRANCH} from ${JSON_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${JSON_BRANCH}" "${JSON_REPO}" "${name}"; then
        die "Failed to clone valkey-json from ${JSON_REPO} (ref ${JSON_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Vendoring RapidJSON ${RAPIDJSON_COMMIT} ..."
    git clone "${RAPIDJSON_REPO}" "${srcdir}/deps/rapidjson" \
        || die "Failed to clone RapidJSON"
    ( cd "${srcdir}/deps/rapidjson" && git checkout -q "${RAPIDJSON_COMMIT}" ) \
        || die "Failed to check out RapidJSON ${RAPIDJSON_COMMIT}"

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../json/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "json/README.packaging.md is missing"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # SBOM of the module source tree (best-effort; written to the sbom/ output
    # dir, not into the tarball). Consistent with the server packages.
    generate_sbom_files "${srcdir}" "${WORKDIR}/json.spdx.json" "${WORKDIR}/json.cdx.json"
    copy_artifacts "sbom" "${WORKDIR}/json.spdx.json" "${WORKDIR}/json.cdx.json"
    rm -f "${WORKDIR}/json.spdx.json" "${WORKDIR}/json.cdx.json"

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-json source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path
    # (mirrors the server's valkey.properties).
    cat > "${WORKDIR}/valkey-json.properties" <<EOF
PRODUCT=${JSON_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${JSON_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-json/${name}/${JSON_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_bloom_sources — fetch valkey-bloom, vendor cargo deps, emit offline tarball
# ---------------------------------------------------------------------------
get_bloom_sources() {
    if [[ "$BLOOM_SOURCE" -eq 0 ]]; then
        log_info "valkey-bloom sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}-${BLOOM_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-bloom ${BLOOM_BRANCH} from ${BLOOM_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${BLOOM_BRANCH}" "${BLOOM_REPO}" "${name}"; then
        die "Failed to clone valkey-bloom from ${BLOOM_REPO} (ref ${BLOOM_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # Vendor all cargo dependencies into the source tree so the package builds
    # fully offline (the cargo analog of vendoring RapidJSON for json).
    log_info "Vendoring cargo dependencies ..."
    export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}" CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
    ( cd "${srcdir}" \
        && cargo generate-lockfile \
        && mkdir -p .cargo \
        && cargo vendor vendor > .cargo/config.toml ) \
        || die "cargo vendor failed (run with --bloom_deps so the Rust toolchain is installed)"

    # cargo vendor records informational "*.orig" files (e.g. Cargo.toml.orig) in
    # each crate's .cargo-checksum.json. dpkg-source's 3.0 (quilt) handling can
    # drop those files, after which an offline cargo build fails with
    # "failed to open file vendor/<crate>/Cargo.toml.orig". Drop the files and
    # their checksum entries so the vendored tree stays self-consistent.
    python3 - "${srcdir}/vendor" <<'PY'
import json, glob, os, sys
vroot = sys.argv[1]
for cs in glob.glob(os.path.join(vroot, '*', '.cargo-checksum.json')):
    with open(cs) as fh:
        data = json.load(fh)
    files = data.get('files', {})
    for key in [k for k in files if k.endswith('.orig')]:
        files.pop(key, None)
        path = os.path.join(os.path.dirname(cs), key)
        if os.path.exists(path):
            os.remove(path)
    with open(cs, 'w') as fh:
        json.dump(data, fh)
PY

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../bloom/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "bloom/README.packaging.md is missing"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # SBOM of the module source tree (best-effort; written to the sbom/ output dir).
    generate_sbom_files "${srcdir}" "${WORKDIR}/bloom.spdx.json" "${WORKDIR}/bloom.cdx.json"
    copy_artifacts "sbom" "${WORKDIR}/bloom.spdx.json" "${WORKDIR}/bloom.cdx.json"
    rm -f "${WORKDIR}/bloom.spdx.json" "${WORKDIR}/bloom.cdx.json"

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-bloom source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path.
    cat > "${WORKDIR}/valkey-bloom.properties" <<EOF
PRODUCT=${BLOOM_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${BLOOM_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-bloom/${name}/${BLOOM_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_search_sources — fetch valkey-search into a source tarball
#   No dependency vendoring: gRPC/Protobuf/Abseil/highwayhash are FetchContent-
#   built at package-build time, and ICU source is already in the repo tree.
# ---------------------------------------------------------------------------
get_search_sources() {
    if [[ "$SEARCH_SOURCE" -eq 0 ]]; then
        log_info "valkey-search sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}-${SEARCH_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-search ${SEARCH_BRANCH} from ${SEARCH_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${SEARCH_BRANCH}" "${SEARCH_REPO}" "${name}"; then
        die "Failed to clone valkey-search from ${SEARCH_REPO} (ref ${SEARCH_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../search/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "search/README.packaging.md is missing"

    # Build-time source tweaks (done here so RPM and DEB build identically):
    #  1) Disable LTO. The release build links the module with -flto and compiles
    #     with -ffat-lto-objects; GCC 12 (the toolchain on Ubuntu jammy and other
    #     older-gcc distros) has an LTO bug — "multiple prevailing defs for
    #     '__ct_comp'" — that fails the link. The module is fine without LTO.
    #     This MUST also cover the vendored snowball stemmer, which otherwise keeps
    #     IPO + -fno-fat-lto-objects (slim, bytecode-only objects). Linking those
    #     into a -fno-lto module drops their machine code, so the module loads with
    #     "undefined symbol: sb_stemmer_length". Skip snowball's IPO block too.
    #  2) Remove the unit-test trees outright. They build test EXECUTABLES (not
    #     needed for packaging) that fail to link on some toolchains: gcc-toolset's
    #     static libstdc++ leaves std:: symbols undefined, and the top-level
    #     testing/ misses test-only link deps. -DBUILD_UNIT_TESTS=OFF (via build.sh
    #     or CMAKE_EXTRA_ARGS) did not reliably take effect, so instead comment out
    #     the add_subdirectory(testing) calls — flag-independent, nothing can re-add
    #     a removed subdir. The module is a shared lib (no --no-undefined) and links
    #     fine on its own. (testing_infra is a plain lib and is left untouched.)
    log_info "Patching valkey-search sources (disable LTO, remove unit tests) ..."
    local vs_cmake="${srcdir}/cmake/Modules/valkey_search.cmake"
    if [[ -f "$vs_cmake" ]]; then
        sed -i 's/-ffat-lto-objects/-fno-lto/g; s/ -flto)/ -fno-lto)/g' "$vs_cmake"
    else
        log_warn "valkey_search.cmake not found — LTO not disabled (upstream layout changed?)"
    fi
    # Snowball stemmer: skip its IPO/LTO block so it emits normal (machine-code)
    # objects that link into the -fno-lto module (else sb_stemmer_* is undefined).
    local snow_cmake="${srcdir}/third_party/snowball/CMakeLists.txt"
    if [[ -f "$snow_cmake" ]]; then
        sed -i 's/^\([[:space:]]*\)if(lto_supported)/\1if(FALSE) # IPO off: module links -fno-lto/' "$snow_cmake"
    fi
    local kill_tests='s/^\([[:space:]]*\)add_subdirectory(testing)/\1# add_subdirectory(testing) # disabled for packaging/'
    [[ -f "${srcdir}/CMakeLists.txt" ]]       && sed -i "$kill_tests" "${srcdir}/CMakeLists.txt"
    [[ -f "${srcdir}/vmsdk/CMakeLists.txt" ]] && sed -i "$kill_tests" "${srcdir}/vmsdk/CMakeLists.txt"
    # Belt-and-suspenders: also flip build.sh's hard-coded -DBUILD_UNIT_TESTS=ON.
    [[ -f "${srcdir}/build.sh" ]] && sed -i 's/-DBUILD_UNIT_TESTS=ON/-DBUILD_UNIT_TESTS=OFF/g' "${srcdir}/build.sh"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # SBOM of the module source tree (best-effort; written to the sbom/ output dir).
    generate_sbom_files "${srcdir}" "${WORKDIR}/search.spdx.json" "${WORKDIR}/search.cdx.json"
    copy_artifacts "sbom" "${WORKDIR}/search.spdx.json" "${WORKDIR}/search.cdx.json"
    rm -f "${WORKDIR}/search.spdx.json" "${WORKDIR}/search.cdx.json"

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-search source tarball"

    cat > "${WORKDIR}/valkey-search.properties" <<EOF
PRODUCT=${SEARCH_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${SEARCH_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-search/${name}/${SEARCH_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_system — detect OS family (rpm vs deb) and platform details
# ---------------------------------------------------------------------------
get_system() {
    ARCH="$(uname -m)"

    if [[ -f /etc/redhat-release ]]; then
        RHEL="$(rpm --eval %rhel)"
        OS_NAME="el${RHEL}"
        OS="rpm"

        # Detect specific RHEL-family distro for EPEL handling
        if [[ -f /etc/oracle-release ]]; then
            PLATFORM_FAMILY="oracle"
        elif [[ -f /etc/fedora-release ]]; then
            PLATFORM_FAMILY="fedora"
        else
            PLATFORM_FAMILY="rhel"
        fi
    elif [[ -f /etc/SuSE-release ]] || [[ -f /etc/SUSE-brand ]] || grep -qi suse /etc/os-release 2>/dev/null; then
        OS="rpm"
        OS_NAME="suse"
        RHEL="0"
        PLATFORM_FAMILY="suse"
    elif [[ -f /etc/system-release ]] && grep -qi "amazon" /etc/system-release 2>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="amzn2023"
        PLATFORM_FAMILY="amazon"
    elif command -v rpm &>/dev/null && ! command -v dpkg &>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="rpm"
        PLATFORM_FAMILY="rhel"
    else
        OS_NAME="$(lsb_release -sc 2>/dev/null || echo unknown)"
        OS="deb"
        PLATFORM_FAMILY="deb"
    fi
}

# ---------------------------------------------------------------------------
# install_deps
# ---------------------------------------------------------------------------
install_deps() {
    if [[ "$INSTALL" -eq 0 ]]; then
        log_info "Dependencies will not be installed"
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        install_deps_rpm
    else
        install_deps_deb
    fi
}

install_deps_rpm() {
    # ── Determine package manager ──
    local pkg_mgr="yum"
    if command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    fi

    if [[ "$PLATFORM_FAMILY" == "suse" ]]; then
        # ── SUSE / openSUSE ──
        log_info "Installing SUSE build dependencies..."
        zypper refresh
        zypper install -y \
            rpm-build rpmdevtools gcc make wget tar gzip git \
            jemalloc-devel libopenssl-devel pkg-config \
            python3 tcl procps chrpath \
            systemd-devel systemd libsystemd0 \
            sysuser-shadow sysuser-tools

        # Documentation deps (optional on SUSE)
        zypper install -y pandoc python3-PyYAML 2>/dev/null \
            || log_warn "pandoc not available on this SUSE version — docs will be skipped"

    else
        # ── RHEL-family: install EPEL where needed ──
        case "$PLATFORM_FAMILY" in
            oracle)
                # Oracle Linux uses its own EPEL packages
                local epel_pkg="oracle-epel-release-el${RHEL}"
                if ! rpm -q "$epel_pkg" &>/dev/null; then
                    log_info "Installing EPEL for Oracle Linux: $epel_pkg"
                    $pkg_mgr install -y "$epel_pkg" \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            rhel)
                # Rocky, Alma, CentOS, generic RHEL
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Installing EPEL repository..."
                    $pkg_mgr install -y epel-release \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            fedora|amazon)
                # Fedora and Amazon Linux have jemalloc-devel in base repos
                log_info "Skipping EPEL (not needed for $PLATFORM_FAMILY)"
                ;;
        esac

        # ── Common RHEL-family packages ──
        log_info "Installing RPM build dependencies..."
        $pkg_mgr install -y \
            rpm-build rpmdevtools gcc make wget tar gzip git \
            jemalloc-devel openssl openssl-devel pkgconfig \
            python3 tcl procps-ng chrpath \
            systemd-devel systemd-rpm-macros

        # Documentation deps (optional)
        $pkg_mgr install -y pandoc python3-pyyaml 2>/dev/null \
            || log_warn "pandoc not available — docs will be skipped"

        $pkg_mgr clean all
    fi
}

install_deps_deb() {
    log_info "Installing DEB build dependencies..."
    apt-get update

    # Core build toolchain
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        build-essential debhelper devscripts dh-exec dpkg-dev \
        fakeroot ca-certificates lsb-release chrpath \
        git wget curl tar gzip make gcc

    # Valkey build dependencies — try all at once, fall back to individual
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        libjemalloc-dev libssl-dev libsystemd-dev \
        libhiredis-dev liblua5.1-dev liblzf-dev \
        lua-bitop-dev lua-cjson-dev \
        pkg-config pkgconf procps \
        tcl tcl-dev tcl-tls openssl \
        dh-python python3 python3-yaml \
        pandoc python3-sphinx python3-sphinx-rtd-theme \
    || {
        log_warn "Some packages not available, trying individually..."
        local -a fallback_pkgs=(
            libjemalloc-dev libssl-dev libsystemd-dev
            libhiredis-dev liblua5.1-dev liblzf-dev
            lua-bitop-dev lua-cjson-dev
            pkg-config pkgconf procps
            tcl tcl-dev tcl-tls openssl
            dh-exec dh-python python3 python3-yaml
            pandoc python3-sphinx python3-sphinx-rtd-theme
        )
        for dep in "${fallback_pkgs[@]}"; do
            DEBIAN_FRONTEND=noninteractive apt-get -y install "$dep" \
                || log_warn "$dep not available"
        done
    }

    # Use mk-build-deps as a safety net if available
    if command -v mk-build-deps &>/dev/null && [[ -f debian/control ]]; then
        log_info "Running mk-build-deps for any remaining dependencies..."
        mk-build-deps --install --remove \
            --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes" \
            debian/control || log_warn "mk-build-deps reported issues (non-critical)"
    fi
}

# ---------------------------------------------------------------------------
# install_deps_json — build deps for the valkey-json module.
#   The module compiles against the system valkeymodule.h shipped by
#   percona-valkey-dev(el), so this sets up the Percona repo (channel from
#   VALKEY_REPO_CHANNEL, default "testing") and installs that package plus the
#   C++ toolchain. Triggered by --json_deps.
# ---------------------------------------------------------------------------
install_deps_json() {
    if [[ "$JSON_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    local channel="${VALKEY_REPO_CHANNEL:-testing}"
    # Percona repo that ships the existing valkey packages (percona-valkey-devel).
    # For 9.1 the percona-release component is "valkey-91" (override if needed).
    local repo_name="${VALKEY_REPO_NAME:-valkey-91}"

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        $pkg_mgr -y install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        $pkg_mgr -y install \
            gcc-c++ cmake make git tar gzip rpm-build rpmdevtools \
            percona-valkey-devel
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y install wget ca-certificates gnupg lsb-release
        wget -qO /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        dpkg -i /tmp/percona-release.deb || apt-get install -f -y
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        apt-get update
        apt-get -y install \
            debhelper devscripts dh-exec dpkg-dev fakeroot \
            cmake g++ make git \
            percona-valkey-dev
    fi
}

# ---------------------------------------------------------------------------
# install_deps_bloom — build deps for the valkey-bloom (Rust) module.
#   Installs clang (libclang for the valkey-module crate's bindgen), the
#   packaging tools, and the Rust toolchain via rustup into system locations
#   so cargo is on PATH for rpmbuild/debuild. No valkey header is required.
#   Triggered by --bloom_deps.
# ---------------------------------------------------------------------------
install_deps_bloom() {
    if [[ "$BLOOM_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        # Do NOT install the full 'curl' package: Amazon Linux 2023 ships
        # curl-minimal (which already provides the curl command), and
        # 'dnf install curl' fails with an unresolvable conflict against it.
        # curl/curl-minimal is present on all RPM targets, so rely on it.
        $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip ca-certificates pkgconfig python3 \
            clang clang-devel rpm-build rpmdevtools \
        || $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip ca-certificates pkgconfig python3 \
            clang rpm-build rpmdevtools
        # Safety net only if no curl command exists at all (rustup needs it):
        # use --allowerasing so it can replace curl-minimal where applicable.
        command -v curl >/dev/null 2>&1 || $pkg_mgr -y install --allowerasing curl || true
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y install \
            build-essential debhelper devscripts dh-exec dpkg-dev fakeroot \
            git curl ca-certificates wget pkg-config python3 \
            clang libclang-dev
    fi

    # Rust toolchain via rustup, installed system-wide so the rustup proxies
    # (cargo/rustc) resolve the toolchain via RUSTUP_HOME for any build user.
    export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
    if [[ ! -x /usr/local/cargo/bin/cargo ]]; then
        curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
    fi
    ln -sf /usr/local/cargo/bin/cargo  /usr/local/bin/cargo
    ln -sf /usr/local/cargo/bin/rustc  /usr/local/bin/rustc
    ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup
    RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo cargo --version \
        || die "cargo not available after rustup install"
}

# ---------------------------------------------------------------------------
# install_deps_search — build deps for the valkey-search (C++20) module.
#   Needs cmake + make, autotools (ICU), openssl/systemd headers, git (the build
#   FetchContent-clones gRPC/Protobuf/Abseil), and a C++20 compiler (g++ >= 12):
#   gcc-toolset on RHEL, g++-12 on Debian/Ubuntu. The build uses the Unix
#   Makefiles generator, so ninja-build is not required. Triggered by --search_deps.
# ---------------------------------------------------------------------------
install_deps_search() {
    if [[ "$SEARCH_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        # Core build tools — all in base/AppStream on every RPM target. The build
        # uses the Unix Makefiles generator (make), so ninja-build (EPEL-only on
        # RHEL, not reliably available) is NOT needed.
        $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip autoconf automake libtool \
            openssl-devel systemd-devel pkgconfig rpm-build rpmdevtools cmake
        # C++20 toolchain (g++ >= 12) — provided differently per distro; %build
        # picks it up. Amazon Linux 2023 has no gcc-toolset but ships gcc14
        # (binaries named gcc14-g++/gcc14-gcc); RHEL 8/9 use gcc-toolset; OL10 /
        # Fedora already default to gcc >= 12.
        if [[ "$PLATFORM_FAMILY" == "amazon" ]]; then
            $pkg_mgr -y install gcc14 gcc14-c++ || true
        else
            $pkg_mgr -y install gcc-toolset-13 \
                || $pkg_mgr -y install gcc-toolset-14 \
                || $pkg_mgr -y install gcc-toolset-12 \
                || true
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y install \
            build-essential debhelper devscripts dh-exec dpkg-dev fakeroot \
            cmake make git autoconf automake libtool pkg-config \
            libssl-dev libsystemd-dev ca-certificates
        # Prefer g++-12 where the default is older (e.g. Ubuntu jammy); best-effort.
        apt-get -y install g++-12 gcc-12 || true
    fi
}

# ---------------------------------------------------------------------------
# build_srpm
# ---------------------------------------------------------------------------
build_srpm() {
    if [[ "$SRPM" -eq 0 ]]; then
        log_info "SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "valkey*.tar.gz"
    local tarfile="$FOUND_FILE"

    # Clean up everything except the tarball
    rm -fr rpmbuild
    find "$WORKDIR" -maxdepth 1 -mindepth 1 \
        ! -name "*.tar.gz" ! -name "source_tarball" ! -name "srpm" \
        ! -name "valkey.properties" \
        -exec rm -rf {} + 2>/dev/null || true

    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    tar vxzf "${WORKDIR}/${tarfile}" --wildcards '*/rpm' --strip=1

    cp -av rpm/* rpmbuild/SOURCES
    cp -av rpm/${PACKAGE_NAME}.spec rpmbuild/SPECS

    mv -fv "$tarfile" "${WORKDIR}/rpmbuild/SOURCES"

    sed -i 's:.rhel7:%{dist}:' "${WORKDIR}/rpmbuild/SPECS/${PACKAGE_NAME}.spec"
    sed -i "s/^Version:.*$/Version:        ${VERSION}/" "${WORKDIR}/rpmbuild/SPECS/${PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" \
        --define "version ${VERSION}" rpmbuild/SPECS/${PACKAGE_NAME}.spec

    copy_artifacts "srpm" rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_rpm
# ---------------------------------------------------------------------------
build_rpm() {
    if [[ "$RPM" -eq 0 ]]; then
        log_info "RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr rb
    mkdir -vp rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" rb/SRPMS/

    RHEL="$(rpm --eval %rhel)"
    ARCH="$(uname -m | sed -e 's:i686:i386:g')"

    rpmbuild --define "_topdir ${WORKDIR}/rb" --define "dist .${OS_NAME}" \
        --define "version ${VERSION}" --rebuild "rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_json_srpm — source RPM for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_srpm() {
    if [[ "$JSON_SRPM" -eq 0 ]]; then
        log_info "valkey-json SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${JSON_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr json_rpmbuild
    mkdir -vp json_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../json/rpm/${JSON_PACKAGE_NAME}.spec" json_rpmbuild/SPECS/
    # Spec patches are kept in json/debian/patches (single source of truth, shared
    # with the DEB quilt series); copy them next to the tarball for rpmbuild.
    cp -av "${BUILDER_SCRIPT_DIR}/../json/debian/patches/"*.patch json_rpmbuild/SOURCES/
    mv -fv "$tarfile" json_rpmbuild/SOURCES/

    # Allow --json_version to flow through to the package version.
    sed -i "s/^Version:.*$/Version:        ${JSON_VERSION}/" \
        "json_rpmbuild/SPECS/${JSON_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/json_rpmbuild" --define "dist .generic" \
        "json_rpmbuild/SPECS/${JSON_PACKAGE_NAME}.spec"

    # SRPMs go to the shared srpm/ dir (same as the server build and what the
    # Jenkins pipeline pushes/pops). build_<module>_rpm finds its own by a
    # module-specific glob, and the server build_rpm runs before any module
    # SRPM exists, so there is no cross-pickup.
    copy_artifacts "srpm" json_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_json_rpm — binary RPM for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_rpm() {
    if [[ "$JSON_RPM" -eq 0 ]]; then
        log_info "valkey-json RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${JSON_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr json_rb
    mkdir -vp json_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" json_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/json_rb" --define "dist .${OS_NAME}" \
        --rebuild "json_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" json_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_source_deb
# ---------------------------------------------------------------------------
build_source_deb() {
    if [[ "$SDEB" -eq 0 ]]; then
        log_info "Source deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    # Clean previous build artifacts but preserve valkey.properties and source_tarball/
    rm -rf "${PRODUCT}-"* "${PACKAGE_NAME}-"* "${PACKAGE_NAME}_"*
    rm -f ./*.dsc ./*.orig.tar.gz ./*.changes ./*.debian.tar.* ./*.diff.*

    find_and_copy_artifact "source_tarball" "valkey*.tar.gz"
    local tarfile="$FOUND_FILE"

    local debian_codename
    debian_codename="$(lsb_release -sc)"
    ARCH="$(uname -m | sed -e 's:i686:i386:g')"

    tar zxf "$tarfile"
    mv "${PRODUCT}-${VERSION}" "${PACKAGE_NAME}-${VERSION}"
    local builddir="${PACKAGE_NAME}-${VERSION}"

    # Repack orig tarball with the correct top-level directory name;
    # dpkg-source expects the orig tarball directory to match the source package name.
    tar czf "${PACKAGE_NAME}_${VERSION}.orig.tar.gz" "$builddir"
    rm -f "$tarfile"

    cd "$builddir" || die "Cannot cd to $builddir"

    # Regenerate the debian changelog
    cd debian || die "Cannot cd to debian"
    rm -rf changelog
    {
        echo "${PACKAGE_NAME} (${VERSION}-${RELEASE}) unstable; urgency=low"
        echo "  * Initial Release."
        echo " -- EvgeniyPatlan <evgeniy.patlan@percona.com> $(date -R)"
    } > changelog
    cd ..

    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" \
        "Update to new ${PACKAGE_NAME} version ${VERSION}"
    dpkg-buildpackage -S

    cd ..

    copy_artifacts "source_deb" ./*_source.changes
    copy_artifacts "source_deb" ./*.dsc
    copy_artifacts "source_deb" ./*.orig.tar.gz
    # 3.0 (quilt) produces .debian.tar.*, older formats produce .diff.*
    copy_artifacts "source_deb" ./*.debian.tar.* 2>/dev/null \
        || copy_artifacts "source_deb" ./*diff* 2>/dev/null \
        || true
}

# ---------------------------------------------------------------------------
# build_deb
# ---------------------------------------------------------------------------
build_deb() {
    if [[ "$DEB" -eq 0 ]]; then
        log_info "Deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    for file in 'dsc' 'orig.tar.gz' 'changes'; do
        find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.${file}"
    done
    # 3.0 (quilt) produces .debian.tar.*, older formats produce .diff.*
    find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.debian.tar.*" \
        || find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*diff*" \
        || true

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"
    rm -fv ./*.deb
    rm -rf "${PACKAGE_NAME}-${VERSION}"

    local debian_codename
    debian_codename="$(lsb_release -sc)"
    ARCH="$(uname -m)"

    echo "DEBIAN=${debian_codename}" >> valkey.properties
    echo "ARCH=${ARCH}" >> valkey.properties

    local dsc
    dsc="$(basename "$(find . -name '*.dsc' | sort | tail -n1)")"

    dpkg-source -x "$dsc"

    cd "${PACKAGE_NAME}-${VERSION}" || die "Cannot cd to ${PACKAGE_NAME}-${VERSION}"

    dch -m -D "$debian_codename" --force-distribution \
        -v "1:${VERSION}-${RELEASE}.${debian_codename}" 'Update distribution'

    # Clear locale variables to avoid dpkg-buildpackage warnings
    # shellcheck disable=SC2046
    unset $(locale | cut -d= -f1) 2>/dev/null || true

    dpkg-buildpackage -rfakeroot -us -uc -b

    copy_artifacts "deb" "$WORKDIR"/*.*deb
}

# ---------------------------------------------------------------------------
# build_json_source_deb — source DEB for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_source_deb() {
    if [[ "$JSON_SDEB" -eq 0 ]]; then
        log_info "valkey-json source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}"
    local ver="${JSON_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    # dpkg-source expects the orig tarball name to match the source package.
    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    # debian/ (including patches/) comes from this repo's json/ tree.
    cp -r "${BUILDER_SCRIPT_DIR}/../json/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "json source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_json_deb — binary DEB for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_deb() {
    if [[ "$JSON_DEB" -eq 0 ]]; then
        log_info "valkey-json deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}"
    local ver="${JSON_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "json dsc not found — run --build_json_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && dpkg-buildpackage -b -us -uc ) \
        || die "json binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# build_bloom_srpm — source RPM for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_srpm() {
    if [[ "$BLOOM_SRPM" -eq 0 ]]; then
        log_info "valkey-bloom SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${BLOOM_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr bloom_rpmbuild
    mkdir -vp bloom_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../bloom/rpm/${BLOOM_PACKAGE_NAME}.spec" bloom_rpmbuild/SPECS/
    mv -fv "$tarfile" bloom_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${BLOOM_VERSION}/" \
        "bloom_rpmbuild/SPECS/${BLOOM_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/bloom_rpmbuild" --define "dist .generic" \
        "bloom_rpmbuild/SPECS/${BLOOM_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" bloom_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_bloom_rpm — binary RPM for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_rpm() {
    if [[ "$BLOOM_RPM" -eq 0 ]]; then
        log_info "valkey-bloom RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${BLOOM_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr bloom_rb
    mkdir -vp bloom_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" bloom_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/bloom_rb" --define "dist .${OS_NAME}" \
        --rebuild "bloom_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" bloom_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_bloom_source_deb — source DEB for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_source_deb() {
    if [[ "$BLOOM_SDEB" -eq 0 ]]; then
        log_info "valkey-bloom source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}"
    local ver="${BLOOM_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../bloom/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "bloom source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_bloom_deb — binary DEB for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_deb() {
    if [[ "$BLOOM_DEB" -eq 0 ]]; then
        log_info "valkey-bloom deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}"
    local ver="${BLOOM_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "bloom dsc not found — run --build_bloom_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && dpkg-buildpackage -b -us -uc ) \
        || die "bloom binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# build_search_srpm — source RPM for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_srpm() {
    if [[ "$SEARCH_SRPM" -eq 0 ]]; then
        log_info "valkey-search SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${SEARCH_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr search_rpmbuild
    mkdir -vp search_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../search/rpm/${SEARCH_PACKAGE_NAME}.spec" search_rpmbuild/SPECS/
    mv -fv "$tarfile" search_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${SEARCH_VERSION}/" \
        "search_rpmbuild/SPECS/${SEARCH_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/search_rpmbuild" --define "dist .generic" \
        "search_rpmbuild/SPECS/${SEARCH_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" search_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_search_rpm — binary RPM for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_rpm() {
    if [[ "$SEARCH_RPM" -eq 0 ]]; then
        log_info "valkey-search RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${SEARCH_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr search_rb
    mkdir -vp search_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" search_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/search_rb" --define "dist .${OS_NAME}" \
        --rebuild "search_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" search_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_search_source_deb — source DEB for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_source_deb() {
    if [[ "$SEARCH_SDEB" -eq 0 ]]; then
        log_info "valkey-search source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}"
    local ver="${SEARCH_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../search/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "search source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_search_deb — binary DEB for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_deb() {
    if [[ "$SEARCH_DEB" -eq 0 ]]; then
        log_info "valkey-search deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}"
    local ver="${SEARCH_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "search dsc not found — run --build_search_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && dpkg-buildpackage -b -us -uc ) \
        || die "search binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# install_deps_bundle — packaging tools for the meta-package. There is nothing
#   to compile; only rpmbuild (RPM) or debhelper/dpkg-dev (DEB) are needed.
# ---------------------------------------------------------------------------
install_deps_bundle() {
    if [[ "$BUNDLE_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        $pkg_mgr -y install rpm-build rpmdevtools
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y install debhelper devscripts dpkg-dev dh-exec fakeroot
    fi
}

# ---------------------------------------------------------------------------
# get_bundle_sources — assemble the percona-valkey-bundle meta-package source.
#   There is no upstream code to clone/compile; the tarball just carries the
#   README + LICENSE so rpmbuild/dpkg have something to package the metadata on.
# ---------------------------------------------------------------------------
get_bundle_sources() {
    if [[ "$BUNDLE_SOURCE" -eq 0 ]]; then
        log_info "valkey-bundle sources will not be assembled"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}-${BUNDLE_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Assembling ${name} (meta-package; no upstream source) ..."
    rm -rf "${srcdir}"
    mkdir -p "${srcdir}"
    cp "${BUILDER_SCRIPT_DIR}/../bundle/README.md" "${srcdir}/README.md" \
        || die "bundle/README.md is missing"
    cp "${BUILDER_SCRIPT_DIR}/../bundle/LICENSE" "${srcdir}/LICENSE" \
        || die "bundle/LICENSE is missing"

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-bundle source tarball"

    cat > "${WORKDIR}/valkey-bundle.properties" <<EOF
PRODUCT=${BUNDLE_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${BUNDLE_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-bundle/${name}/${BUNDLE_VERSION}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# build_bundle_srpm — source RPM for the percona-valkey-bundle meta-package
# ---------------------------------------------------------------------------
build_bundle_srpm() {
    if [[ "$BUNDLE_SRPM" -eq 0 ]]; then
        log_info "valkey-bundle SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${BUNDLE_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr bundle_rpmbuild
    mkdir -vp bundle_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../bundle/rpm/${BUNDLE_PACKAGE_NAME}.spec" bundle_rpmbuild/SPECS/
    mv -fv "$tarfile" bundle_rpmbuild/SOURCES/

    # Allow --bundle_version to flow through to the package version.
    sed -i "s/^Version:.*$/Version:        ${BUNDLE_VERSION}/" \
        "bundle_rpmbuild/SPECS/${BUNDLE_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/bundle_rpmbuild" --define "dist .generic" \
        "bundle_rpmbuild/SPECS/${BUNDLE_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" bundle_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_bundle_rpm — binary (per-arch) RPM for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_rpm() {
    if [[ "$BUNDLE_RPM" -eq 0 ]]; then
        log_info "valkey-bundle RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${BUNDLE_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr bundle_rb
    mkdir -vp bundle_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" bundle_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/bundle_rb" --define "dist .${OS_NAME}" \
        --rebuild "bundle_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" bundle_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_bundle_source_deb — source DEB for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_source_deb() {
    if [[ "$BUNDLE_SDEB" -eq 0 ]]; then
        log_info "valkey-bundle source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}"
    local ver="${BUNDLE_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../bundle/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "bundle source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_bundle_deb — binary (per-arch) DEB for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_deb() {
    if [[ "$BUNDLE_DEB" -eq 0 ]]; then
        log_info "valkey-bundle deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}"
    local ver="${BUNDLE_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "bundle dsc not found — run --build_bundle_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && dpkg-buildpackage -b -us -uc ) \
        || die "bundle binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ===========================================================================
# Main
# ===========================================================================
CURDIR="$(pwd)"
WORKDIR=""
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
OS_NAME=""
ARCH=""
OS=""
PLATFORM_FAMILY=""
RHEL="0"
INSTALL=0
BRANCH="$DEFAULT_BRANCH"
REPO="$DEFAULT_REPO"
VERSION="$DEFAULT_VERSION"
RELEASE="$DEFAULT_RELEASE"
LOCAL_BUILD=0
JSON_DEPS=0
JSON_SOURCE=0
JSON_SRPM=0
JSON_RPM=0
JSON_SDEB=0
JSON_DEB=0
JSON_REPO="$DEFAULT_JSON_REPO"
JSON_VERSION="$DEFAULT_JSON_VERSION"
JSON_BRANCH=""
BLOOM_DEPS=0
BLOOM_SOURCE=0
BLOOM_SRPM=0
BLOOM_RPM=0
BLOOM_SDEB=0
BLOOM_DEB=0
BLOOM_REPO="$DEFAULT_BLOOM_REPO"
BLOOM_VERSION="$DEFAULT_BLOOM_VERSION"
BLOOM_BRANCH=""
SEARCH_DEPS=0
SEARCH_SOURCE=0
SEARCH_SRPM=0
SEARCH_RPM=0
SEARCH_SDEB=0
SEARCH_DEB=0
SEARCH_REPO="$DEFAULT_SEARCH_REPO"
SEARCH_VERSION="$DEFAULT_SEARCH_VERSION"
SEARCH_BRANCH=""
BUNDLE_DEPS=0
BUNDLE_SOURCE=0
BUNDLE_SRPM=0
BUNDLE_RPM=0
BUNDLE_SDEB=0
BUNDLE_DEB=0
BUNDLE_VERSION="$DEFAULT_BUNDLE_VERSION"

parse_arguments "$@"

# Default each module's git ref to its version (a tag) unless overridden.
JSON_BRANCH="${JSON_BRANCH:-$JSON_VERSION}"
BLOOM_BRANCH="${BLOOM_BRANCH:-$BLOOM_VERSION}"
SEARCH_BRANCH="${SEARCH_BRANCH:-$SEARCH_VERSION}"

# PRODUCT_FULL is set after parsing so --version can override; exported for child processes
export PRODUCT_FULL="${PRODUCT}-${VERSION}-${RELEASE}"

if [[ $# -eq 0 ]]; then
    usage
fi

check_workdir
get_system
install_deps
install_deps_json
install_deps_bloom
install_deps_search
install_deps_bundle
get_sources
get_json_sources
get_bloom_sources
get_search_sources
get_bundle_sources
build_srpm
build_source_deb
build_rpm
build_deb
build_json_srpm
build_json_rpm
build_json_source_deb
build_json_deb
build_bloom_srpm
build_bloom_rpm
build_bloom_source_deb
build_bloom_deb
build_search_srpm
build_search_rpm
build_search_source_deb
build_search_deb
build_bundle_srpm
build_bundle_rpm
build_bundle_source_deb
build_bundle_deb
