# Fixture stand-in for the pre-rename valkey-admin-server package, used only
# by tests/test-upgrade.sh to exercise the rename upgrade's file conflict
# and Provides/Obsoletes resolution. It ships the exact same unbranded
# paths rpm/percona-valkey-admin.spec ships today (the systemd unit, the
# sysusers/tmpfiles fragments, the env conffile, the data directory) plus a
# marker file at the pre-rename payload root /usr/lib/valkey-admin-server --
# no application payload, no npm build, no BuildRequires beyond the
# sysusers macros, and no git or network dependency. This stands in for
# building an actual pre-rename commit in a throwaway git worktree or
# checkout, which this repository has no such commit for at all (this
# packaging builds from a fetched upstream release archive, not an
# adjacent valkey-admin working tree) -- and even where one might exist it
# would be local to a single branch and stop existing the moment it is
# squashed, rebased, or cloned shallow, which would make the upgrade test
# permanently unbuildable through no fault of its own.
%global appdir %{_prefix}/lib/valkey-admin-server

Name:           valkey-admin
Version:        %{_version}
Release:        1%{?dist}
Summary:        Fixture stand-in for the pre-rename valkey-admin-server package
License:        Apache-2.0
Source1:        valkey-admin.sysusers
Source2:        valkey-admin.service
Source3:        valkey-admin.tmpfiles
Source4:        valkey-admin.env
BuildRequires:  systemd-rpm-macros

%description
Fixture stand-in for the pre-rename valkey-admin package. Test
infrastructure only -- never built or shipped as a real artifact.

%package server
Summary:        Fixture stand-in for the pre-rename valkey-admin-server package
Requires(pre): shadow-utils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
%if %{undefined sysusers_create_compat}
%else
%sysusers_requires_compat
%endif
%description server
Fixture stand-in for the pre-rename headless server subpackage. Test
infrastructure only -- never built or shipped as a real artifact.

%install
mkdir -p %{buildroot}%{appdir}
echo "pre-rename fixture payload marker" > %{buildroot}%{appdir}/marker

install -Dm0644 %{SOURCE2} %{buildroot}%{_unitdir}/valkey-admin.service
install -Dm0644 %{SOURCE1} %{buildroot}%{_sysusersdir}/valkey-admin.conf
install -Dm0644 %{SOURCE3} %{buildroot}%{_tmpfilesdir}/valkey-admin.conf
install -Dm0640 %{SOURCE4} %{buildroot}%{_sysconfdir}/valkey-admin/valkey-admin.env
mkdir -p %{buildroot}%{_sharedstatedir}/valkey-admin

%if %{undefined sysusers_create_compat}
# EL8 has no sysusers rpm macros; create the service user directly. Matches
# the real spec's %%pre so the fixture behaves the same way on every target.
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
%dir %{appdir}
%{appdir}/marker
%{_unitdir}/valkey-admin.service
%{_sysusersdir}/valkey-admin.conf
%{_tmpfilesdir}/valkey-admin.conf
%dir %attr(0750,root,valkey-admin) %{_sysconfdir}/valkey-admin
%config(noreplace) %attr(0640,root,valkey-admin) %{_sysconfdir}/valkey-admin/valkey-admin.env
%dir %attr(0750,valkey-admin,valkey-admin) %{_sharedstatedir}/valkey-admin

%changelog
* Tue Sep 22 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.1.1-1
- Fixture stand-in for the pre-rename valkey-admin-server package
