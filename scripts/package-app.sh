#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/Media Compressor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

VERSION="0.3.1"
BUILD="4"

# Cache static ffmpeg/ffprobe binaries between packaging runs
CACHE_DIR="$ROOT/.build/ffmpeg-cache"
FFMPEG_URL="https://www.osxexperts.net/ffmpeg711arm.zip"
FFPROBE_URL="https://www.osxexperts.net/ffprobe711arm.zip"
# SHA-256 pins for the extracted binaries. Run once with PIN_NEW_BINARIES=1
# to record them after verifying the download; every later run must match.
CHECKSUM_FILE="$ROOT/scripts/ffmpeg-binaries.sha256"

cd "$ROOT"

# The bundled ffmpeg/ffprobe are arm64-only, so the app is built arm64-only too
# and declares it in Info.plist. An Intel build would launch but fail to encode.
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CACHE_DIR"

cp "$BIN_DIR/VideoCompressor" "$MACOS_DIR/VideoCompressor"
chmod +x "$MACOS_DIR/VideoCompressor"

pinned_checksum() {
    local name="$1"
    [ -f "$CHECKSUM_FILE" ] || return 0
    awk -v n="$name" '$2 == n { print $1 }' "$CHECKSUM_FILE"
}

verify_binary() {
    local name="$1"
    local path="$2"
    local actual expected
    actual="$(shasum -a 256 "$path" | awk '{ print $1 }')"
    expected="$(pinned_checksum "$name")"

    if [ -z "$expected" ]; then
        if [ "${PIN_NEW_BINARIES:-0}" = "1" ]; then
            echo "$actual  $name" >> "$CHECKSUM_FILE"
            echo "Pinned $name sha256 $actual in $CHECKSUM_FILE"
            return 0
        fi
        echo "No pinned SHA-256 for $name (got $actual)." >&2
        echo "Verify the binary, then rerun with PIN_NEW_BINARIES=1 to record it." >&2
        exit 1
    fi

    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch for $name: expected $expected, got $actual" >&2
        echo "Refusing to bundle it. Delete $CACHE_DIR to re-download." >&2
        exit 1
    fi
}

fetch_static_binary() {
    local name="$1"
    local url="$2"
    local cached_zip="$CACHE_DIR/${name}.zip"
    local cached_bin="$CACHE_DIR/${name}"

    if [ ! -f "$cached_bin" ]; then
        echo "Downloading $name from $url"
        curl -fL --retry 3 --connect-timeout 30 -o "$cached_zip" "$url"
        unzip -o -q "$cached_zip" -d "$CACHE_DIR"
        rm -f "$cached_zip"
        if [ ! -f "$cached_bin" ]; then
            echo "Expected $cached_bin not found after unzip" >&2
            exit 1
        fi
        chmod +x "$cached_bin"
    fi

    # Checked on every run, so a tampered cache is caught as well.
    verify_binary "$name" "$cached_bin"

    if ! lipo -archs "$cached_bin" 2>/dev/null | grep -qw arm64; then
        echo "$name is not an arm64 binary" >&2
        exit 1
    fi

    cp "$cached_bin" "$RESOURCES_DIR/$name"
    chmod +x "$RESOURCES_DIR/$name"
    # Remove quarantine flag so the bundled binary doesn't trigger Gatekeeper
    xattr -d com.apple.quarantine "$RESOURCES_DIR/$name" 2>/dev/null || true
}

fetch_static_binary "ffmpeg" "$FFMPEG_URL"
fetch_static_binary "ffprobe" "$FFPROBE_URL"

# Bundled typefaces (Archivo, Schibsted Grotesk), registered at launch
mkdir -p "$RESOURCES_DIR/Fonts"
cp "$ROOT"/Sources/VideoCompressorApp/Resources/Fonts/*.ttf "$RESOURCES_DIR/Fonts/"

# App icon, drawn by scripts/make-icon.swift and cached until that script changes
ICON_CACHE="$ROOT/.build/icon-cache"
if [ ! -f "$ICON_CACHE/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE/AppIcon.icns" ]; then
    mkdir -p "$ICON_CACHE"
    swift "$ROOT/scripts/make-icon.swift" "$ICON_CACHE/AppIcon.iconset"
    iconutil -c icns "$ICON_CACHE/AppIcon.iconset" -o "$ICON_CACHE/AppIcon.icns"
fi
cp "$ICON_CACHE/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VideoCompressor</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.MediaCompressor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Media Compressor</string>
    <key>CFBundleDisplayName</key>
    <string>Media Compressor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audio</string>
            </array>
        </dict>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSRequiresNativeExecution</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature over the finished bundle so the resources are sealed and
# Apple Silicon launches it without complaint.
codesign --force --deep --sign - "$APP_DIR"

echo "Created $APP_DIR"
