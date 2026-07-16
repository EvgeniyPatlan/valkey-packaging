#!/bin/sh
# bundle-module-libs.sh — assemble a self-contained Valkey module tree.
#
# Copies a module .so together with its non-glibc shared-library closure into
# OUT_DIR, then sets RUNPATH to $ORIGIN on every copied object so the module
# resolves its private libraries from its own directory when dlopen'd by a
# server that runs in a different container (i.e. the injected .so lives on a
# shared volume that is not on the loader's default search path).
#
# The glibc / dynamic-loader set is deliberately NOT bundled: those must come
# from the host server process, otherwise a second libc is mapped into it and
# the server crashes.
#
# Usage: bundle-module-libs.sh <module.so> <out_dir>

set -eu

SO="${1:?usage: bundle-module-libs.sh <module.so> <out_dir>}"
OUT="${2:?usage: bundle-module-libs.sh <module.so> <out_dir>}"

[ -f "$SO" ] || { echo "ERROR: module not found: $SO" >&2; exit 1; }
command -v patchelf >/dev/null 2>&1 || { echo "ERROR: patchelf not found" >&2; exit 1; }

# Components provided by the server's own glibc — never ship these alongside a
# module, or two libc's end up mapped into one process.
is_glibc_core() {
    case "$1" in
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|\
        libresolv.so.*|libutil.so.*|libnsl.so.*|libanl.so.*|libcrypt.so.*|\
        ld-linux*.so.*|ld.so.*) return 0 ;;
        *) return 1 ;;
    esac
}

mkdir -p "$OUT"
install -m 0755 "$SO" "$OUT/$(basename "$SO")"

# ldd prints the flattened dependency closure; copy every non-glibc entry.
ldd "$SO" | awk '/=>/ {print $3}' | while read -r lib; do
    [ -n "${lib:-}" ] && [ -f "$lib" ] || continue
    base="$(basename "$lib")"
    is_glibc_core "$base" && continue
    [ -e "$OUT/$base" ] && continue
    cp -L "$lib" "$OUT/$base"
    chmod 0644 "$OUT/$base"
done

# Every shipped object (module + siblings) resolves its neighbours locally.
for f in "$OUT"/*.so "$OUT"/*.so.*; do
    [ -f "$f" ] || continue
    patchelf --set-rpath '$ORIGIN' --force-rpath "$f"
done
