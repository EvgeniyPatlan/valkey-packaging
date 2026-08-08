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
