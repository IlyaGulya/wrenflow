#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACT="$REPO_DIR/support/macos.env"

if [[ ! -f "$CONTRACT" ]]; then
    echo "macOS support contract is missing: $CONTRACT" >&2
    exit 64
fi

# shellcheck disable=SC1090
source "$CONTRACT"

fail() {
    echo "macOS support verification failed: $*" >&2
    exit 1
}

require_literal() {
    local literal="$1"
    local path="$2"
    grep -Fq -- "$literal" "$path" || fail "$path must contain: $literal"
}

reject_literal() {
    local literal="$1"
    local path="$2"
    if grep -Fq -- "$literal" "$path"; then
        fail "$path contains unsupported contract: $literal"
    fi
}

version_is_greater() {
    local candidate="$1"
    local ceiling="$2"
    awk -v candidate="$candidate" -v ceiling="$ceiling" '
        BEGIN {
            candidate_parts = split(candidate, a, ".")
            ceiling_parts = split(ceiling, b, ".")
            count = candidate_parts > ceiling_parts ? candidate_parts : ceiling_parts
            for (i = 1; i <= count; i++) {
                left = (i in a) ? a[i] + 0 : 0
                right = (i in b) ? b[i] + 0 : 0
                if (left > right) exit 0
                if (left < right) exit 1
            }
            exit 1
        }
    '
}

macho_minos() {
    local artifact="$1"
    otool -l "$artifact" | awk '
        $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") {
            command = $2
            inspect = 1
            next
        }
        inspect && command == "LC_BUILD_VERSION" && $1 == "minos" {
            print $2
            exit
        }
        inspect && command == "LC_VERSION_MIN_MACOSX" && $1 == "version" {
            print $2
            exit
        }
    '
}

verify_macho() {
    local artifact="$1"
    local architectures minimum
    [[ -f "$artifact" ]] || fail "Mach-O is missing: $artifact"
    architectures="$(lipo -archs "$artifact" 2>/dev/null)" || fail "not a Mach-O: $artifact"
    [[ "$architectures" == "$WRENFLOW_MACOS_ARCH" ]] ||
        fail "$artifact has architecture '$architectures'; expected exactly '$WRENFLOW_MACOS_ARCH'"
    minimum="$(macho_minos "$artifact")"
    [[ -n "$minimum" ]] || fail "$artifact has no macOS minimum-version load command"
    if version_is_greater "$minimum" "$WRENFLOW_MACOS_MIN"; then
        fail "$artifact requires macOS $minimum; bundle declares $WRENFLOW_MACOS_MIN"
    fi
    printf 'support_macho=%s arch=%s minos=%s\n' "$artifact" "$architectures" "$minimum"
}

verify_source_contract() {
    local plist="$REPO_DIR/native/wrenflow-gpui/macos/Info.plist"
    local workflow="$REPO_DIR/.github/workflows/build.yml"
    local build_script="$REPO_DIR/native/wrenflow-gpui/scripts/build-app.sh"
    local build_rs="$REPO_DIR/native/wrenflow-gpui/build.rs"
    local app_manifest="$REPO_DIR/native/wrenflow-gpui/Cargo.toml"
    local plist_floor high_resolution plist_accessory

    plist_floor="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"
    [[ "$plist_floor" == "$WRENFLOW_MACOS_MIN" ]] ||
        fail "Info.plist floor is $plist_floor, contract is $WRENFLOW_MACOS_MIN"
    high_resolution="$(plutil -extract NSHighResolutionCapable raw -o - "$plist")"
    [[ "$high_resolution" == "true" ]] || fail "Info.plist must enable high-resolution rendering"
    plist_accessory="$(plutil -extract LSUIElement raw -o - "$plist")"
    [[ "$plist_accessory" == "true" ]] || fail "Info.plist must declare the menu-bar accessory launch contract"

    require_literal "rust = \"$WRENFLOW_RUST_VERSION\"" "$REPO_DIR/mise.toml"
    require_literal "ORT_VERSION=\"$WRENFLOW_ORT_VERSION\"" "$REPO_DIR/scripts/download-ort.sh"
    require_literal "onnxruntime-osx-arm64-\${ORT_VERSION}.tgz" "$REPO_DIR/scripts/download-ort.sh"
    require_literal "--target \"\$WRENFLOW_RUST_TARGET\"" "$build_script"
    # These are deliberately literal source-code invariants.
    # shellcheck disable=SC2016
    require_literal 'source "$REPO_DIR/support/macos.env"' "$build_script"
    # shellcheck disable=SC2016
    require_literal '"$(uname -m)" != "$WRENFLOW_MACOS_ARCH"' "$build_script"
    require_literal 'Ok("aarch64") => "arm64"' "$build_rs"
    require_literal "unwrap_or_else(|_| \"$WRENFLOW_MACOS_MIN\".into())" "$build_rs"
    reject_literal 'Ok("x86_64") => "x86_64"' "$build_rs"
    require_literal 'features = ["font-kit"]' "$app_manifest"
    reject_literal '"runtime_shaders"' "$app_manifest"
    require_literal '[tasks.setup-app-dependencies]' "$REPO_DIR/mise.toml"
    require_literal 'mise run setup-app-dependencies' "$workflow"
    require_literal '"$REPO_DIR/scripts/verify-gpui-shader-contract.sh"' "$build_script"
    require_literal 'shaders.metallib' "$build_script"
    require_literal 'stitched_shaders.metal' "$build_script"

    require_literal "runs-on: $WRENFLOW_MIN_RUNNER" "$workflow"
    require_literal "Select Xcode $WRENFLOW_MIN_XCODE" "$workflow"
    require_literal "/Applications/Xcode_$WRENFLOW_MIN_XCODE.app" "$workflow"
    require_literal "runs-on: $WRENFLOW_CURRENT_RUNNER" "$workflow"
    require_literal "Select Xcode $WRENFLOW_CURRENT_XCODE" "$workflow"
    require_literal "/Applications/Xcode_$WRENFLOW_CURRENT_XCODE.app" "$workflow"
    reject_literal "runs-on: macos-latest" "$workflow"

    require_literal "macOS ${WRENFLOW_MACOS_MIN%.*}+ · Apple Silicon" "$REPO_DIR/README.md"
    require_literal "Intel Macs are not supported" "$REPO_DIR/docs/macos-support.md"
    require_literal "Pre-GPUI releases and their data are outside the support contract" \
        "$REPO_DIR/docs/macos-support.md"

    if [[ -f "$REPO_DIR/supply-chain/pins.json" ]]; then
        jq -e --arg version "$WRENFLOW_ORT_VERSION" '
            .onnx_runtime.version == $version and
            (.onnx_runtime.url | contains("onnxruntime-osx-arm64-"))
        ' "$REPO_DIR/supply-chain/pins.json" >/dev/null ||
            fail "supply-chain ORT pin does not match the arm64 support contract"
    fi

    printf 'support_source_contract=ok macos_min=%s arch=%s rust_target=%s\n' \
        "$WRENFLOW_MACOS_MIN" "$WRENFLOW_MACOS_ARCH" "$WRENFLOW_RUST_TARGET"
}

verify_metal_toolchain() {
    local fixture="$REPO_DIR/scripts/fixtures/support-probe.metal"
    local temp_dir air_file metallib_file
    [[ -f "$fixture" ]] || fail "Metal support probe fixture is missing"
    xcrun --sdk macosx -f metal >/dev/null 2>&1 ||
        fail "selected Xcode does not provide the Metal compiler"
    xcrun --sdk macosx -f metallib >/dev/null 2>&1 ||
        fail "selected Xcode does not provide the metallib linker"
    temp_dir="$(mktemp -d)"
    air_file="$temp_dir/support-probe.air"
    metallib_file="$temp_dir/support-probe.metallib"
    if ! xcrun --sdk macosx metal \
        -gline-tables-only \
        -mmacosx-version-min=10.15.7 \
        -MO \
        -c "$fixture" \
        -o "$air_file" >/dev/null 2>&1; then
        rm -rf "$temp_dir"
        fail "selected Xcode could not compile the Metal support probe"
    fi
    if ! xcrun --sdk macosx metallib "$air_file" -o "$metallib_file" >/dev/null 2>&1; then
        rm -rf "$temp_dir"
        fail "selected Xcode could not link the Metal support probe"
    fi
    [[ -s "$metallib_file" ]] || {
        rm -rf "$temp_dir"
        fail "selected Xcode produced an empty Metal library"
    }
    rm -rf "$temp_dir"
    printf 'support_metal_toolchain=ok xcode=%s\n' "$(xcodebuild -version | awk 'NR == 1 {print $2}')"
}

verify_host() {
    local architecture os_version os_major
    [[ "$(uname -s)" == "Darwin" ]] || fail "production builds require macOS"
    architecture="$(uname -m)"
    [[ "$architecture" == "$WRENFLOW_MACOS_ARCH" ]] ||
        fail "production builds require $WRENFLOW_MACOS_ARCH; host is $architecture"
    os_version="$(sw_vers -productVersion)"
    os_major="${os_version%%.*}"
    if version_is_greater "$WRENFLOW_MACOS_MIN" "$os_version"; then
        fail "host macOS $os_version is below $WRENFLOW_MACOS_MIN"
    fi
    if (( os_major > WRENFLOW_MACOS_CURRENT_MAJOR )); then
        fail "host macOS $os_version is newer than validated major $WRENFLOW_MACOS_CURRENT_MAJOR"
    fi
    printf 'support_host=ok os=%s arch=%s\n' "$os_version" "$architecture"
}

verify_ci_host() {
    local tier="$1"
    local expected_major expected_xcode actual_xcode actual_major
    verify_host
    case "$tier" in
        minimum)
            expected_major="${WRENFLOW_MACOS_MIN%%.*}"
            expected_xcode="$WRENFLOW_MIN_XCODE"
            ;;
        current)
            expected_major="$WRENFLOW_MACOS_CURRENT_MAJOR"
            expected_xcode="$WRENFLOW_CURRENT_XCODE"
            ;;
        *) fail "unknown CI support tier: $tier" ;;
    esac
    actual_major="$(sw_vers -productVersion | cut -d. -f1)"
    [[ "$actual_major" == "$expected_major" ]] ||
        fail "$tier CI must run macOS $expected_major, got $(sw_vers -productVersion)"
    actual_xcode="$(xcodebuild -version | awk 'NR == 1 {print $2}')"
    [[ "$actual_xcode" == "$expected_xcode" ]] ||
        fail "$tier CI must select Xcode $expected_xcode, got $actual_xcode"
    verify_metal_toolchain
    printf 'support_ci_host=ok tier=%s os=%s xcode=%s arch=%s\n' \
        "$tier" "$(sw_vers -productVersion)" "$actual_xcode" "$(uname -m)"
}

verify_bundle() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local binary="$app/Contents/MacOS/wrenflow"
    local shell_dylib="$app/Contents/Frameworks/libWrenflowShell.dylib"
    local ort_dylib="$app/Contents/MacOS/libonnxruntime.dylib"
    local bundle_floor

    [[ -d "$app" ]] || fail "app bundle is missing: $app"
    bundle_floor="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"
    [[ "$bundle_floor" == "$WRENFLOW_MACOS_MIN" ]] ||
        fail "bundle floor is $bundle_floor, contract is $WRENFLOW_MACOS_MIN"
    [[ "$(plutil -extract NSHighResolutionCapable raw -o - "$plist")" == "true" ]] ||
        fail "bundle does not enable high-resolution rendering"
    verify_macho "$binary"
    verify_macho "$shell_dylib"
    verify_macho "$ort_dylib"
    printf 'support_bundle=ok path=%s macos_min=%s arch=%s\n' \
        "$app" "$bundle_floor" "$WRENFLOW_MACOS_ARCH"
}

case "${1:-}" in
    source)
        verify_source_contract
        ;;
    host)
        verify_host
        ;;
    ci)
        [[ $# -eq 2 ]] || fail "usage: $0 ci <minimum|current>"
        verify_source_contract
        verify_ci_host "$2"
        ;;
    metal)
        [[ $# -eq 1 ]] || fail "usage: $0 metal"
        verify_metal_toolchain
        ;;
    macho)
        [[ $# -eq 2 ]] || fail "usage: $0 macho <path>"
        verify_macho "$2"
        ;;
    bundle)
        [[ $# -eq 2 ]] || fail "usage: $0 bundle <Wrenflow.app>"
        verify_source_contract
        verify_bundle "$2"
        ;;
    *)
        echo "Usage: $0 <source|host|ci <minimum|current>|metal|macho <path>|bundle <Wrenflow.app>>" >&2
        exit 64
        ;;
esac
