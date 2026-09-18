#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/Media Compressor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

VERSION="0.3.0"
BUILD="3"

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
