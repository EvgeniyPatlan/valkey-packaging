#!/bin/sh
#
# gen-module-sbom.sh — generate the embedded SBOM set for a Percona Valkey module.
#
# Shipped inside each module's source tarball (added by valkey_builder.sh
# get_<module>_sources) and invoked from the module's RPM spec (%install) and
# Debian rules (override_dh_auto_install), so the SBOM reflects the *built* tree.
#
# Usage: gen-module-sbom.sh PKG_NAME VERSION DEST_DIR [SCAN_DIR]
#
# Produces, in DEST_DIR:
#   PKG.spdx.json      SPDX (JSON)
#   PKG.cdx.json       CycloneDX (JSON)
#   PKG.spdx           SPDX (tag-value, text)
#   PKG.cdx.xml        CycloneDX (XML)
#   PKG.sbom.txt       Human-readable component table (Syft table)
#   PKG.licenses.txt   Condensed "name version license" manifest (derived)
#
set -eu

PKG="${1:?usage: gen-module-sbom.sh PKG VERSION DEST_DIR [SCAN_DIR]}"
VER="${2:?missing VERSION}"
DEST="${3:?missing DEST_DIR}"
SCAN="${4:-.}"

# Syft is installed system-wide by valkey_builder.sh --<module>_deps. Fail loudly
# rather than ship an empty/placeholder SBOM.
if ! command -v syft >/dev/null 2>&1; then
    echo "ERROR: syft not found; cannot generate SBOM for ${PKG}" >&2
    exit 1
fi

mkdir -p "$DEST"

# One scan, multiple output formats. --exclude keeps non-dependency metadata out
# of the catalog: the module's own debian/ and rpm/ packaging dirs, and .github/
# (CI workflows — Syft would otherwise catalog GitHub Actions as "packages",
# which are dev-time tooling, not components shipped in the package).
syft scan "dir:${SCAN}" \
    --source-name "$PKG" --source-version "$VER" \
    --exclude './debian' --exclude './rpm' \
    --exclude './.github' --exclude './.git' \
    -o "spdx-json=${DEST}/${PKG}.spdx.json" \
    -o "cyclonedx-json=${DEST}/${PKG}.cdx.json" \
    -o "spdx-tag-value=${DEST}/${PKG}.spdx" \
    -o "cyclonedx-xml=${DEST}/${PKG}.cdx.xml" \
    -o "syft-table=${DEST}/${PKG}.sbom.txt"

# Derive a condensed "name version license" manifest from the SPDX tag-value
# output using awk only (no jq/python dependency in the build container).
awk '
    /^PackageName:/           { n=$2 }
    /^PackageVersion:/        { v=$2 }
    /^PackageLicenseDeclared:/{ l=substr($0, index($0, ": ")+2); if (n!="") printf "%s %s %s\n", n, v, l; n="" }
' "${DEST}/${PKG}.spdx" | sort -u > "${DEST}/${PKG}.licenses.txt"

echo "SBOM (spdx/cdx json+xml, table, licenses) written to ${DEST} for ${PKG} ${VER}"
