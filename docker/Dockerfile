FROM redhat/ubi9-minimal

LABEL org.opencontainers.image.authors="info@percona.com" \
      org.opencontainers.image.source="https://github.com/valkey-io/valkey" \
      org.opencontainers.image.vendor="Percona" \
      org.opencontainers.image.title="Percona Valkey" \
      org.opencontainers.image.description="Percona Valkey image built from Percona RPM package" \
      org.opencontainers.image.version="9.1.0"

RUN microdnf -y update; \
    microdnf -y install glibc-langpack-en

ENV VALKEY_VERSION=9.1.0

ARG REPO_CHANNEL=testing

# check repository package signature in secure way
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 4D1BB29D63D98E422B2113B19334A25F8507EFA5 99DB70FAE1D7CE227FB6488205B555B38483C65D; \
    gpg --batch --export --armor 4D1BB29D63D98E422B2113B19334A25F8507EFA5 > ${GNUPGHOME}/PERCONA-PACKAGING-KEY; \
    gpg --batch --export --armor 99DB70FAE1D7CE227FB6488205B555B38483C65D > ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    rpmkeys --import ${GNUPGHOME}/PERCONA-PACKAGING-KEY ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    microdnf install -y findutils; \
    curl -Lf -o /tmp/percona-release.rpm https://repo.percona.com/yum/percona-release-latest.noarch.rpm; \
    rpmkeys --checksig /tmp/percona-release.rpm; \
    rpm -i /tmp/percona-release.rpm; \
    rm -rf "$GNUPGHOME" /tmp/percona-release.rpm; \
    rpm --import /etc/pki/rpm-gpg/PERCONA-PACKAGING-KEY; \
    percona-release disable all; \
    percona-release enable valkey-91 ${REPO_CHANNEL}; \
    microdnf -y install \
        tar \
        procps-ng \
        shadow-utils \
        percona-valkey; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

RUN mkdir /data && chown valkey:valkey /data
VOLUME /data
WORKDIR /data

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

USER valkey

EXPOSE 6379
CMD ["valkey-server"]
