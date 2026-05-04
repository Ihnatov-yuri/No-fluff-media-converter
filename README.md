# No-Fluff Media Converter

A small, fast macOS app for compressing video and audio files. No upsells, no telemetry, no fluff.

- Drop video files → MP4 (H.264 or HEVC) or MOV
- Drop audio files (e.g. WAV) → MP3
- Mixed queues work — each file is auto-routed by type
- Quality mode (CRF) or target-size mode (two-pass)
- Side-by-side comparison view with frame extraction

Built with Swift + SwiftUI, wraps `ffmpeg`/`ffprobe`.

## Requirements

- macOS 13 or later
- [`ffmpeg`](https://ffmpeg.org) and `ffprobe` installed and on PATH

```sh
brew install ffmpeg
```

## Install

### Download the prebuilt app

Grab the latest `Media Compressor.app` from the [Releases](https://github.com/Ihnatov-yuri/No-fluff-media-converter/releases) page.

The app is unsigned (no Apple Developer account), so the first time you launch it you'll need to:

1. Right-click the app → **Open**
2. Confirm the warning dialog

After the first launch macOS will remember your choice.

### Build from source

```sh
git clone https://github.com/Ihnatov-yuri/No-fluff-media-converter.git
cd No-fluff-media-converter
./scripts/package-app.sh
open "dist/Media Compressor.app"
```

Or run directly via Swift Package Manager:

```sh
swift run VideoCompressor
```

## Development

Run the test/check suite:

```sh
swift run VideoCompressorChecks
```

Project layout:

- `Sources/VideoCompressorCore` — settings, ffmpeg command building, probing, runner
- `Sources/VideoCompressorApp` — SwiftUI app, view model, comparison view
- `Sources/VideoCompressorChecks` — unit + integration checks (runs ffmpeg if available)
- `scripts/package-app.sh` — builds release and packages the `.app` bundle

## License

[MIT](LICENSE) — do whatever you want with it.

`ffmpeg` itself is not bundled; users install it separately via Homebrew.
