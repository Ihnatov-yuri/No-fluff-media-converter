#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/Media Compressor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Cache static ffmpeg/ffprobe binaries between packaging runs
CACHE_DIR="$ROOT/.build/ffmpeg-cache"
FFMPEG_URL="https://www.osxexperts.net/ffmpeg711arm.zip"
FFPROBE_URL="https://www.osxexperts.net/ffprobe711arm.zip"

cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CACHE_DIR"

cp "$BIN_DIR/VideoCompressor" "$MACOS_DIR/VideoCompressor"
chmod +x "$MACOS_DIR/VideoCompressor"

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

    cp "$cached_bin" "$RESOURCES_DIR/$name"
    chmod +x "$RESOURCES_DIR/$name"
    # Remove quarantine flag so the bundled binary doesn't trigger Gatekeeper
    xattr -d com.apple.quarantine "$RESOURCES_DIR/$name" 2>/dev/null || true
}

fetch_static_binary "ffmpeg" "$FFMPEG_URL"
fetch_static_binary "ffprobe" "$FFPROBE_URL"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
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
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

echo "Created $APP_DIR"
