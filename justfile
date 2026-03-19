# Wrenflow build system

app_name := "Wrenflow Debug"
bundle_id := "me.gulya.wrenflow.debug"
release_app_name := "Wrenflow"
release_bundle_id := "me.gulya.wrenflow"
build_dir := "build"
app_bundle := build_dir / app_name + ".app"
release_bundle := build_dir / release_app_name + ".app"
contents := app_bundle / "Contents"
macos_dir := contents / "MacOS"
resources := contents / "Resources"
icon_svg := "Resources/logo.svg"
icon_source := "Resources/AppIcon-Source.png"
icon_icns := "Resources/AppIcon.icns"
icon_bg := "#f5f3f0"
icon_padding := "80"
rust_dir := "core"

# Signing: defaults to ad-hoc, override with env var for real signing
codesign_identity := env("WRENFLOW_CODESIGN_IDENTITY", "-")

# Install git hooks for conventional commit validation
setup-hooks:
    git config core.hooksPath .githooks
    @echo "Git hooks installed. Commits will be validated for conventional commit format."

# Default: build debug
default: build

# Build the full debug app (Rust + UniFFI + Swift + bundle)
build: rust uniffi swift bundle

# Build only Rust core + FFI
rust:
    cd {{rust_dir}} && cargo build -p wrenflow-ffi

# Generate UniFFI Swift bindings + copy C header
uniffi: rust
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p Sources/Generated FFIModule
    cd {{rust_dir}}
    cargo run -p uniffi-bindgen generate \
        --library target/debug/libwrenflow_ffi.dylib \
        --language swift \
        --out-dir ../Sources/Generated
    cd ..
    cp Sources/Generated/wrenflow_ffiFFI.h FFIModule/wrenflow_ffiFFI.h
    echo "Generated UniFFI bindings"

# Build Swift app
swift:
    swift build -c debug

# Create debug .app bundle
bundle: swift
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{macos_dir}}" "{{resources}}"
    cp "$(swift build -c debug --show-bin-path)/Wrenflow" "{{macos_dir}}/{{app_name}}"
    cp Info.plist "{{contents}}/"
    plutil -replace CFBundleName -string "{{app_name}}" "{{contents}}/Info.plist"
    plutil -replace CFBundleDisplayName -string "{{app_name}}" "{{contents}}/Info.plist"
    plutil -replace CFBundleExecutable -string "{{app_name}}" "{{contents}}/Info.plist"
    plutil -replace CFBundleIdentifier -string "{{bundle_id}}" "{{contents}}/Info.plist"
    # Inject version from Cargo.toml (source of truth) and build number from git
    VERSION=$(grep -m1 'version = ' {{rust_dir}}/Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
    BUILD_NUMBER=$(git rev-list --count HEAD)
    plutil -replace CFBundleShortVersionString -string "$VERSION" "{{contents}}/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "{{contents}}/Info.plist"
    cp {{icon_icns}} "{{resources}}/"
    BIN_PATH="$(swift build -c debug --show-bin-path)"
    cp "$BIN_PATH/WrenflowCLI" "{{macos_dir}}/wrenflow"
    if [ "{{codesign_identity}}" = "-" ]; then
        codesign --force --sign - --entitlements Wrenflow.entitlements "{{app_bundle}}"
    else
        codesign --force --sign "{{codesign_identity}}" --options runtime --entitlements Wrenflow.entitlements --timestamp "{{app_bundle}}"
    fi
    echo "Built {{app_bundle}}"

# Build and run (kill existing instance first)
run: build
    -pkill -f "{{app_name}}" 2>/dev/null; sleep 0.5
    open "{{app_bundle}}"

# Run with setup wizard reset
run-setup: build
    defaults delete {{bundle_id}} 2>/dev/null; true
    -pkill -f "{{app_name}}" 2>/dev/null; sleep 0.5
    open "{{app_bundle}}"

# Build release (universal binary, hardened runtime, signed)
release: rust-release uniffi
    #!/usr/bin/env bash
    set -euo pipefail
    BUNDLE="{{release_bundle}}"
    CONTENTS="$BUNDLE/Contents"
    MACOS="$CONTENTS/MacOS"
    RES="$CONTENTS/Resources"
    mkdir -p "$MACOS" "$RES"

    swift build -c release --arch arm64
    cp "$(swift build -c release --arch arm64 --show-bin-path)/Wrenflow" "$MACOS/{{release_app_name}}"

    cp Info.plist "$CONTENTS/"
    plutil -replace CFBundleName -string "{{release_app_name}}" "$CONTENTS/Info.plist"
    plutil -replace CFBundleDisplayName -string "{{release_app_name}}" "$CONTENTS/Info.plist"
    plutil -replace CFBundleExecutable -string "{{release_app_name}}" "$CONTENTS/Info.plist"
    plutil -replace CFBundleIdentifier -string "{{release_bundle_id}}" "$CONTENTS/Info.plist"
    VERSION=$(grep -m1 'version = ' {{rust_dir}}/Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
    BUILD_NUMBER=$(git rev-list --count HEAD)
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
    cp {{icon_icns}} "$RES/"

    cp "$(swift build -c release --arch arm64 --show-bin-path)/WrenflowCLI" "$MACOS/wrenflow"

    IDENTITY="{{codesign_identity}}"
    if [ "$IDENTITY" = "-" ]; then
        echo "WARNING: Release build with ad-hoc signing. Set WRENFLOW_CODESIGN_IDENTITY for proper signing."
        codesign --force --sign - --entitlements Wrenflow.entitlements "$BUNDLE"
    else
        codesign --force --sign "$IDENTITY" --options runtime --entitlements Wrenflow.entitlements --timestamp "$BUNDLE"
    fi
    echo "Built $BUNDLE"

# Build Rust in release mode (arm64 only — ONNX Runtime lacks x86_64 prebuilt)
rust-release:
    cd {{rust_dir}} && cargo build -p wrenflow-ffi --release

# Build CLI tool only
cli:
    @mkdir -p "{{build_dir}}"
    swift build -c debug --product WrenflowCLI
    @cp "$(swift build -c debug --show-bin-path)/WrenflowCLI" "{{build_dir}}/wrenflow"
    @echo "Built {{build_dir}}/wrenflow"

# Install CLI to /usr/local/bin
install-cli: cli
    cp "{{build_dir}}/wrenflow" /usr/local/bin/wrenflow
    @echo "Installed to /usr/local/bin/wrenflow"

# Generate AppIcon-Source.png from SVG (requires rsvg-convert + imagemagick)
icon-source:
    #!/usr/bin/env bash
    set -euo pipefail
    SIZE=1024
    ICON_SIZE=$((SIZE * {{icon_padding}} / 100))
    # Render SVG keeping aspect ratio, then pad to square
    rsvg-convert "{{icon_svg}}" --keep-aspect-ratio -w "$ICON_SIZE" -h "$ICON_SIZE" -o /tmp/wrenflow_icon_fg.png
    # Pad to exact square with transparency
    magick /tmp/wrenflow_icon_fg.png -gravity center -background none -extent "${ICON_SIZE}x${ICON_SIZE}" /tmp/wrenflow_icon_fg_sq.png
    # Colorize: white SVG -> dark icon matching WrenflowStyle text color (0.15 = #262626)
    magick /tmp/wrenflow_icon_fg_sq.png -fill "#262626" -colorize 100 /tmp/wrenflow_icon_fg_dark.png
    # Shift slightly right (+20px) to visually center the asymmetric bird
    magick -size "${SIZE}x${SIZE}" "xc:{{icon_bg}}" /tmp/wrenflow_icon_fg_dark.png -geometry +20+0 -gravity center -composite "{{icon_source}}"
    rm -f /tmp/wrenflow_icon_fg.png /tmp/wrenflow_icon_fg_sq.png /tmp/wrenflow_icon_fg_dark.png
    echo "Generated {{icon_source}}"

# Generate app icon from source PNG
icon: icon-source
    @mkdir -p {{build_dir}}/AppIcon.iconset
    @sips -z 16 16 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_16x16.png > /dev/null
    @sips -z 32 32 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_16x16@2x.png > /dev/null
    @sips -z 32 32 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_32x32.png > /dev/null
    @sips -z 64 64 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_32x32@2x.png > /dev/null
    @sips -z 128 128 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_128x128.png > /dev/null
    @sips -z 256 256 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_128x128@2x.png > /dev/null
    @sips -z 256 256 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_256x256.png > /dev/null
    @sips -z 512 512 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_256x256@2x.png > /dev/null
    @sips -z 512 512 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_512x512.png > /dev/null
    @sips -z 1024 1024 {{icon_source}} --out {{build_dir}}/AppIcon.iconset/icon_512x512@2x.png > /dev/null
    @iconutil -c icns -o {{icon_icns}} {{build_dir}}/AppIcon.iconset
    @rm -rf {{build_dir}}/AppIcon.iconset
    @echo "Generated {{icon_icns}}"

# Create DMG installer
dmg: release
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f {{build_dir}}/{{release_app_name}}.dmg
    rm -rf {{build_dir}}/dmg-staging
    mkdir -p {{build_dir}}/dmg-staging
    cp -R "{{release_bundle}}" {{build_dir}}/dmg-staging/
    create-dmg \
        --volname "{{release_app_name}}" \
        --volicon "{{icon_icns}}" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "{{release_app_name}}.app" 180 170 \
        --hide-extension "{{release_app_name}}.app" \
        --app-drop-link 480 170 \
        --no-internet-enable \
        {{build_dir}}/{{release_app_name}}.dmg \
        {{build_dir}}/dmg-staging || true
    rm -rf {{build_dir}}/dmg-staging

    IDENTITY="{{codesign_identity}}"
    if [ "$IDENTITY" != "-" ]; then
        codesign --force --sign "$IDENTITY" --timestamp {{build_dir}}/{{release_app_name}}.dmg
    fi
    echo "Created {{build_dir}}/{{release_app_name}}.dmg"

# Notarize DMG (requires APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD env vars)
notarize:
    xcrun notarytool submit {{build_dir}}/{{release_app_name}}.dmg \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait --timeout 600
    xcrun stapler staple {{build_dir}}/{{release_app_name}}.dmg
    @echo "Notarized and stapled."

# Clean all build artifacts
clean:
    rm -rf {{build_dir}} .build
    cd {{rust_dir}} && cargo clean

# Check everything compiles
check:
    cd {{rust_dir}} && cargo check
    swift build -c debug

# ── Logging ──

# Show recent app logs (last N minutes, default 5)
logs minutes="5":
    /usr/bin/log show --predicate 'process CONTAINS "Wrenflow"' --last "{{minutes}}m" --style compact

# Show only errors/crashes (last N minutes, default 30)
crashes minutes="30":
    /usr/bin/log show --predicate 'process CONTAINS "Wrenflow"' --last "{{minutes}}m" --style compact | grep -iE "fatal|crash|signal|abort|exception|EXC_|SIGABRT|SIGSEGV|FAULT|Terminating|uncaught"

# Stream live logs (Ctrl+C to stop)
logs-live:
    /usr/bin/log stream --predicate 'process CONTAINS "Wrenflow"' --style compact

# Run app from terminal with stdout visible (for print() debugging)
run-debug: build
    -pkill -f "{{app_name}}" 2>/dev/null; sleep 0.3
    "{{app_bundle}}/Contents/MacOS/{{app_name}}"
