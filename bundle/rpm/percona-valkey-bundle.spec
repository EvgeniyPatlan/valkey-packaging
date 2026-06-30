%global valkey_modules_abi 1

Name:           percona-valkey-bundle
Version:        9.1.0
Release:        1%{?dist}
Summary:        Percona Valkey server bundled with all supported modules
BuildArch:      noarch

License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-bundle
Source0:        percona-valkey-bundle-%{version}.tar.gz

# This is a meta-package: it ships no binaries of its own. Installing it pulls
# in the Percona Valkey server together with every supported module, so the
# whole stack is present with a single install. Versions track the curated
# bundle set (see valkey-io/valkey-bundle versions.json for 9.1):
#   server 9.1.0, json 1.0.2, bloom 1.0.1, search 1.2.0, ldap 1.1.0.
Requires:       percona-valkey >= 9.1.0
Requires:       percona-valkey-json >= 1.0.2
Requires:       percona-valkey-bloom >= 1.0.1
Requires:       percona-valkey-search >= 1.2.0
Requires:       percona-valkey-ldap >= 1.1.0

%description
percona-valkey-bundle is a meta-package that installs the Percona Valkey server
together with all supported modules in one step:

  * percona-valkey-json    (JSON.*  — native JSON data type)
  * percona-valkey-bloom   (BF.*    — Bloom filters)
  * percona-valkey-search  (FT.*    — vector / full-text search)
  * percona-valkey-ldap    (LDAP authentication)

It contains no files of its own; it only declares dependencies. The modules are
installed into the Valkey module directory but are not loaded automatically;
enable them with 'loadmodule' in valkey.conf or 'MODULE LOAD' at runtime.

%prep
%autosetup -p1 -n percona-valkey-bundle-%{version}

%build
# Nothing to build — this is a dependency-only meta-package.

%install
# No payload; only the documentation handled by %%license / %%doc below.

%files
%license LICENSE
%doc README.md

%changelog
* Sun Jun 29 2026 Percona Build <info@percona.com> - 9.1.0-1
- Initial percona-valkey-bundle meta-package (server + json/bloom/search/ldap).
