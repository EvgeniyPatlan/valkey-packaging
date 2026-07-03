%global valkey_name        valkey
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules
%global valkey_modules_abi 1

# Rust release builds carry no DWARF debuginfo; skip the (empty) debug package.
%global debug_package %{nil}

Name:           percona-valkey-bloom
Version:        1.0.1
Release:        1%{?dist}
Summary:        Bloom filter module for Percona Valkey

License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-bloom
Source0:        percona-valkey-bloom-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  pkgconfig
# libclang, used by the valkey-module crate's bindgen build step.
BuildRequires:  clang
# Note: the Rust toolchain (cargo/rustc) is provided out-of-band via rustup
# (valkey_builder.sh --bloom_deps), so it is not expressed as a BuildRequires.

Requires:       percona-valkey%{?_isa}
Requires:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

%description
valkey-bloom provides a Bloom filter data type for Percona Valkey via the
libvalkey_bloom.so loadable module (BF.ADD, BF.EXISTS, BF.RESERVE, BF.INSERT,
BF.INFO, ...). The module is installed into the Valkey module directory; it is
not loaded automatically. Enable it with 'loadmodule' in valkey.conf or
'MODULE LOAD' at runtime.

%prep
%autosetup -n percona-valkey-bloom-%{version}

%build
# Rust toolchain installed system-wide by --bloom_deps.
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH="/usr/local/cargo/bin:/usr/local/bin:${PATH}"
# Fully offline: cargo dependencies are vendored into ./vendor with a
# .cargo/config.toml redirect, so no crates.io access is needed.
cargo build --release --offline

%install
# The modules directory itself is owned by percona-valkey; this package only
# installs the module file into it.
install -d %{buildroot}%{valkey_modules_dir}
install -m 0755 target/release/libvalkey_bloom.so %{buildroot}%{valkey_modules_dir}/libvalkey_bloom.so

# Embedded SBOM set (SPDX/CycloneDX json+xml, Syft table, license manifest),
# generated from the built tree by the shipped gen-module-sbom.sh (catalogs the
# vendored cargo crates). Syft is put on PATH by valkey_builder.sh --bloom_deps;
# the script fails loudly if it is missing.
sh gen-module-sbom.sh %{name} %{version} %{buildroot}%{_datadir}/%{name}/sbom .

%files
%license LICENSE
%doc README.md README.packaging.md
%{valkey_modules_dir}/libvalkey_bloom.so
%{_datadir}/%{name}/

%changelog
* Tue Jun 24 2026 Percona Build <info@percona.com> - 1.0.1-1
- Initial percona-valkey-bloom package (upstream valkey-bloom 1.0.1)
