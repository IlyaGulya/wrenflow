#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_DIR/native/wrenflow-gpui/Cargo.toml"
RUST_TARGET="aarch64-apple-darwin"

fail() {
    echo "GPUI shader contract verification failed: $*" >&2
    exit 1
}

verify_tree() {
    local tree="$1"
    grep -Fq 'gpui v0.2.2' "$tree" || fail "effective graph does not contain pinned gpui 0.2.2"
    grep -Fq 'gpui feature "font-kit"' "$tree" || fail "effective graph does not enable the production font-kit feature"
    if grep -Fq 'gpui feature "runtime_shaders"' "$tree"; then
        fail "effective production graph enables runtime Metal source compilation"
    fi
}

case "${1:-}" in
    --tree-file)
        [[ $# -eq 2 && -f "$2" ]] || fail "usage: $0 --tree-file <cargo-tree-output>"
        verify_tree "$2"
        ;;
    "")
        tree="$(mktemp)"
        trap 'rm -f "$tree"' EXIT
        cargo tree \
            --manifest-path "$MANIFEST" \
            --locked \
            --offline \
            --target "$RUST_TARGET" \
            --edges normal,build \
            --config 'source.crates-io.registry="sparse+https://index.crates.io/"' \
            -e features \
            -i gpui@0.2.2 >"$tree"
        verify_tree "$tree"
        ;;
    *) fail "usage: $0 [--tree-file <cargo-tree-output>]" ;;
esac

echo "GPUI production graph uses build-time embedded Metal shaders"
