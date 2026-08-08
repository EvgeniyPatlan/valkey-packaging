#!/bin/bash
set -euo pipefail

VARIANT="${1:-slim}"
IMAGE="${CONTAINER_IMAGE:-amazonlinux:2023}"
CHANNEL="${VALKEY_REPO_CHANNEL:-release}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

docker run --rm \
    -v "$WORKDIR":/images:ro \
    -w /images \
    "$IMAGE" \
    bash -c "
        set -euo pipefail
        dnf -y install ansible-core findutils procps-ng shadow-utils >/dev/null
        ansible-playbook -i localhost, -c local ansible/valkey-ami.yml \
            -e valkey_variant=${VARIANT} \
            -e valkey_repo_channel=${CHANNEL}
    "
