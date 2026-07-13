# Third-Party Software

The packaged `Media Compressor.app` bundle includes the following third-party
binaries inside `Contents/Resources/`:

## ffmpeg and ffprobe

- **Version**: 7.1.1 (Apple Silicon static build)
- **Source build**: provided by [osxexperts.net](https://www.osxexperts.net/)
- **Upstream project**: <https://ffmpeg.org>
- **Source code**: <https://ffmpeg.org/download.html>
- **License**: GNU General Public License, version 2 or later (GPL-2.0-or-later)

The bundled `ffmpeg` and `ffprobe` are built with `--enable-gpl` and link
against components such as `libx264`, `libx265`, and others under GPL terms.
Distributing these binaries places this app's distribution under the GPL
for the bundled binaries only. Media Compressor's own source code remains
licensed under the MIT License (see [LICENSE](LICENSE)).

### Obtaining the source

You can download the complete corresponding source for the bundled ffmpeg
build from the upstream project:

- Tarball downloads: <https://ffmpeg.org/download.html>
- Git: `git clone https://git.ffmpeg.org/ffmpeg.git`

The macOS Apple Silicon build configuration used by osxexperts.net is
documented on their site.

### Full GPL license text

A copy of the GNU General Public License v2 is available at
<https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt>, and v3 at
<https://www.gnu.org/licenses/gpl-3.0.txt>.

## Build from source without bundled ffmpeg

If you'd prefer not to use the bundled binaries, build from source — the app
falls back to a system-wide `ffmpeg`/`ffprobe` (e.g. `brew install ffmpeg`)
when no bundled binaries are present in `Contents/Resources/`.
