# No-Fluff Media Converter

A small, fast macOS app for compressing video and audio files. No upsells, no telemetry, no fluff.

- Drop video files → MP4 (H.264 or HEVC) or MOV
- Drop audio files (e.g. WAV) → MP3
- Mixed queues work — each file is auto-routed by type
- Quality mode (CRF) or target-size mode (two-pass)
- Optional silence speed-up: quiet stretches (≥1s) play at 2-8x while speech stays at normal pace — great for lectures, meetings, and screen recordings
- Side-by-side comparison view with frame extraction

Built with Swift + SwiftUI, wraps `ffmpeg`/`ffprobe`.

## Requirements

- macOS 13 or later (Apple Silicon)
- The prebuilt `.app` from Releases bundles `ffmpeg` and `ffprobe` — no separate install needed.
- If you build from source without running the packaging script, you'll need `ffmpeg` and `ffprobe` on PATH (e.g. `brew install ffmpeg`).

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

Media Compressor's own source is [MIT](LICENSE) — do whatever you want with it.

The packaged `.app` bundles static `ffmpeg`/`ffprobe` binaries (Apple Silicon, from [osxexperts.net](https://www.osxexperts.net/)), which are licensed under the **GPL**. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the GPL distribution notice and source links.
