%global valkey_name        valkey
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules
%global valkey_modules_abi 1

# The module statically links gRPC/Protobuf/Abseil/ICU; the resulting debuginfo
# is huge and not useful for downstream, so skip the debug package.
%global debug_package %{nil}

Name:           percona-valkey-search
Version:        1.2.0
Release:        1%{?dist}
Summary:        Vector and full-text search module for Percona Valkey

License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-search
Source0:        percona-valkey-search-%{version}.tar.gz

BuildRequires:  cmake >= 3.16
BuildRequires:  ninja-build
BuildRequires:  make
BuildRequires:  git
BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  libtool
BuildRequires:  pkgconfig
BuildRequires:  openssl-devel
BuildRequires:  systemd-devel
# A C++20 toolchain (g++ >= 12) is provided out-of-band by
# valkey_builder.sh --search_deps (gcc-toolset on RHEL), so it is not a
# BuildRequires; %build sources the toolset if present.

Requires:       percona-valkey%{?_isa}
Requires:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

%description
valkey-search provides a search index data type for Percona Valkey via the
libsearch.so loadable module (FT.CREATE, FT.SEARCH, FT.INFO, FT.AGGREGATE,
FT.DROPINDEX, ...), supporting vector similarity and full-text queries. The
module is installed into the Valkey module directory; it is not loaded
automatically. Enable it with 'loadmodule' in valkey.conf or 'MODULE LOAD'.

Note: this package compiles its dependencies (gRPC, Protobuf, Abseil, ICU,
highwayhash) from source at build time, which requires network access.

%prep
%autosetup -n percona-valkey-search-%{version}

%build
# Enable a C++20 toolchain (gcc-toolset) if one is installed; RHEL 8/9 default
# gcc is < 12, so --search_deps installs gcc-toolset and we source it here.
for ts in gcc-toolset-13 gcc-toolset-14 gcc-toolset-12; do
    if [ -f /opt/rh/${ts}/enable ]; then
        source /opt/rh/${ts}/enable
        break
    fi
done
# build.sh builds ICU from source, FetchContent-builds gRPC/Protobuf/Abseil/
# highwayhash, then compiles the module -> .build-release/libsearch.so.
CMAKE_EXTRA_ARGS="-DBUILD_UNIT_TESTS=OFF" ./build.sh --jobs=%{?_smp_build_ncpus}%{!?_smp_build_ncpus:$(nproc)}

%install
install -d %{buildroot}%{valkey_modules_dir}
install -m 0755 .build-release/libsearch.so %{buildroot}%{valkey_modules_dir}/libsearch.so

%files
%license LICENSE
%doc README.md README.packaging.md
%{valkey_modules_dir}/libsearch.so

%changelog
* Wed Jun 25 2026 Percona Build <info@percona.com> - 1.2.0-1
- Initial percona-valkey-search package (upstream valkey-search 1.2.0)
