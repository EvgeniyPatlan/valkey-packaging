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
        --help                          Print usage
Example: $0 --builddir=/tmp/BUILD --get_sources --build_src_rpm --build_rpm
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

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    tar --owner=0 --group=0 --exclude=.git -czf "${product_full}.tar.gz" "$product_full"

    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${product_full}/${BRANCH}/${revision}/${BUILD_ID:-}" >> valkey.properties

    copy_artifacts "source_tarball" "${product_full}.tar.gz"

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

parse_arguments "$@"

# PRODUCT_FULL is set after parsing so --version can override; exported for child processes
export PRODUCT_FULL="${PRODUCT}-${VERSION}-${RELEASE}"

if [[ $# -eq 0 ]]; then
    usage
fi

check_workdir
get_system
install_deps
get_sources
build_srpm
build_source_deb
build_rpm
build_deb
