%bcond_with desktop

%global product_name percona-valkey-admin
%global appdir   %{_prefix}/lib/%{product_name}-server
%global srcname  valkey-admin

%global debug_package %{nil}

Name:           %{product_name}
Version:        %{_version}
Release:        2%{?dist}
Summary:        Administration tool for Valkey clusters and standalone instances
License:        Apache-2.0
URL:            https://valkey-admin.valkey.io
Source0:        https://github.com/valkey-io/%{srcname}/archive/refs/tags/v%{version}/%{srcname}-%{version}.tar.gz
# sysusers_create_compat expands via a shell-exec macro at spec-parse time,
# before %prep unpacks Source0 -- an in-tree relative path would not exist yet
# and the generator would silently emit an empty scriptlet. Ship the fragment
# as its own Source so %%{SOURCE1} is an absolute path that already exists.
Source1:        valkey-admin.sysusers
Source2:        valkey-admin.service
Source3:        valkey-admin.tmpfiles
Source4:        valkey-admin.env
# Shipped as %%doc below (see the %%files server comment next to it for why).
Source5:        README.packaging.md
# Not shipped -- executed in %%build. The upstream tarball (Source0) does not
# contain this packaging's own build tooling; it never did, on any version.
Source6:        build-server-payload.sh
# The epoch matters, not just decoration: every EL/Fedora/Amazon nodejs
# and nodejs22 package carries Epoch 1, and rpm/libsolv let epoch dominate
# version comparison entirely. An unqualified "nodejs >= 20" -- or
# "nodejs22 >= 22" -- is satisfied by ANY epoch-1 provider regardless of
# its actual version, because the epoch alone already outranks an
# implicit epoch 0 on the unqualified side; the version number named in
# the requirement is never even reached. Both branches must be pinned, not
# just the first one -- a package literally named "nodejs22" is not a
# guarantee against this, only a same-epoch version comparison is. See the
# %package server Requires below for why the nodejs22 branch exists at all.
BuildRequires:  (nodejs >= 1:20 or nodejs22 >= 1:22)
BuildRequires:  systemd-rpm-macros

%description
Valkey Admin is an administration tool for Valkey clusters and standalone
instances, providing dashboards, a key browser, command execution, cluster
topology and activity monitoring.

%package server
Summary:        Valkey Admin headless web server
# Two independent reasons this is a rich, epoch-pinned dependency rather
# than a plain "nodejs >= 20":
#
# 1. Epoch. Every EL/Fedora/Amazon nodejs AND nodejs22 package carries
#    Epoch 1. rpm and libsolv let epoch dominate version comparison
#    completely: an unqualified "nodejs >= 20" or "nodejs22 >= 22"
#    (implicit epoch 0) is satisfied by ANY epoch-1 provider of that name
#    regardless of actual version, including a hypothetical node 18 --
#    the version number is never even reached. That is not a build-time
#    curiosity: on a real system, dnf would silently resolve an unpinned
#    form by installing the epoch-1 package regardless of its version,
#    satisfying the dependency while violating the floor it names. BOTH
#    branches are pinned (>= 1:20, >= 1:22) to force a genuine same-epoch
#    version comparison on each -- the package being named "nodejs22"
#    is a naming convention, not a version guarantee, and does not by
#    itself close this gap.
# 2. Naming. Amazon Linux 2023 ships Node.js as parallel-installable
#    versioned streams (nodejs18, nodejs20, nodejs22, ...) with no
#    unversioned "nodejs" alias at all in its build image -- only
#    nodejs22 is ever installed there, so BuildRequires has nothing named
#    "nodejs" to compare against. The "or nodejs22" branch is what that
#    image can actually satisfy.
Requires:       (nodejs >= 1:20 or nodejs22 >= 1:22)
Requires(pre): shadow-utils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
# Release is bumped to 2 specifically to give Obsoletes headroom over a
# hypothetical last pre-rename valkey-admin-server at 1.1.1-1: a strict
# "< %%{version}-%%{release}" now reads as "< 1.1.1-2", which correctly
# matches an installed valkey-admin-server at 1.1.1-1 (confirmed directly
# by tests/test-upgrade.sh: dnf schedules its removal and the
# rename install resolves cleanly over every path the two packages share --
# the systemd unit, the sysusers/tmpfiles fragments, the env file, the data
# directory, all deliberately unbranded and identical between the two
# packages). This also covers a cross-dist edge a same-release "<=" form
# does not: EVRs compare dist tags as part of the release, so 1.1.1-1.el9
# sorts higher than 1.1.1-1.el8, and an operator with the el9 old package
# installing this el8 new package would get no obsoletion under
# "<= 1.1.1-1.el8" and hit the file conflict again. Under "< 1.1.1-2.el8"
# it still matches, because release comparison reaches the leading "1" vs
# "2" before the dist suffix is ever considered. Because Provides sits at
# %%{version}-%%{release} (1.1.1-2) and Obsoletes is strictly less than
# that, the two never overlap and rpmlint's self-obsoletion check has
# nothing to flag -- no filter needed in rpmlint.toml.
Provides:       valkey-admin-server = %{version}-%{release}
Obsoletes:      valkey-admin-server < %{version}-%{release}
# %%sysusers_requires_compat is undefined on EL8 (no systemd-rpm-macros
# package there -- see the %%pre conditional below). Referencing it bare
# would leave literal unexpanded text in the preamble and fail spec
# parsing with "Unknown tag", so only emit it where it is defined.
%if %{undefined sysusers_create_compat}
%else
%sysusers_requires_compat
%endif
%description server
Headless Valkey Admin web server, managed by systemd. Serves the web interface
and spawns one metrics collector per monitored Valkey node.

%prep
%autosetup -n %{srcname}-%{version}

%build
# The upstream release tarball (Source0) carries no packaging/ directory on
# any version -- this build helper is this packaging's own, supplied as
# Source6 because it is not something %%files ever ships, only executes.
bash %{SOURCE6} "$(pwd)" "$(pwd)/_payload"

%install
mkdir -p %{buildroot}%{appdir}
cp -a _payload/. %{buildroot}%{appdir}/

install -Dm0644 %{SOURCE2} \
  %{buildroot}%{_unitdir}/valkey-admin.service
install -Dm0644 %{SOURCE1} \
  %{buildroot}%{_sysusersdir}/valkey-admin.conf
install -Dm0644 %{SOURCE3} \
  %{buildroot}%{_tmpfilesdir}/valkey-admin.conf
install -Dm0640 %{SOURCE4} \
  %{buildroot}%{_sysconfdir}/valkey-admin/valkey-admin.env
mkdir -p %{buildroot}%{_sharedstatedir}/valkey-admin

# Copied into the build directory (not the upstream tarball's own tree) so
# %%doc below can reference it by a plain relative name, the same way
# %%doc NOTICES already does for a file that IS in the upstream tarball.
cp %{SOURCE5} README.packaging.md

%if %{undefined sysusers_create_compat}
# EL8 has no sysusers rpm macros; create the service user directly.
%pre server
getent group valkey-admin >/dev/null || groupadd -r valkey-admin
getent passwd valkey-admin >/dev/null || \
  useradd -r -g valkey-admin -d /var/lib/valkey-admin -s /sbin/nologin \
          -c "Valkey Admin service" valkey-admin
exit 0
%else
%pre server
%sysusers_create_compat %{SOURCE1}
%endif

%post server
%systemd_post valkey-admin.service

%preun server
%systemd_preun valkey-admin.service

%postun server
%systemd_postun_with_restart valkey-admin.service

%files server
%license LICENSE
# README.packaging.md cannot be %%doc'd straight from packaging/ any more --
# there is no adjacent packaging/ directory inside the upstream tarball, so
# it ships as Source5 and gets copied into place in %%install above, same
# treatment as the systemd unit / sysusers / tmpfiles / env sources. NOTICES
# is unaffected: it IS part of the upstream tarball (Source0), at its root,
# same as LICENSE.
%doc README.packaging.md
%doc NOTICES
%dir %{appdir}
%{appdir}/*
%{_unitdir}/valkey-admin.service
%{_sysusersdir}/valkey-admin.conf
%{_tmpfilesdir}/valkey-admin.conf
%dir %attr(0750,root,valkey-admin) %{_sysconfdir}/valkey-admin
%config(noreplace) %attr(0640,root,valkey-admin) %{_sysconfdir}/valkey-admin/valkey-admin.env
%dir %attr(0750,valkey-admin,valkey-admin) %{_sharedstatedir}/valkey-admin

%changelog
* Tue Sep 22 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.1.1-2
- Bump Release to 2 and switch Obsoletes to the strict-less-than form so
  the rename upgrade resolves without a same-EVR self-obsoletion overlap
* Mon Sep 21 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.1.1-1
- Package the 1.1.1 release from the upstream valkey-admin source tarball,
  ported from the downstream/packaging working-tree-snapshot build to the
  percona/valkey-packaging convention of building from a real release
  archive with numbered auxiliary Sources
