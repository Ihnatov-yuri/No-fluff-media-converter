#!/usr/bin/env python3
"""Speed up silent parts of a video while keeping speech at normal speed.
Two-step approach: normalize to CFR first, then apply speed changes."""

import subprocess
import re
import sys
import os
import argparse
import tempfile


def detect_silence(input_file, noise_level="-30dB", min_duration=0.5):
    cmd = [
        "ffmpeg", "-i", input_file,
        "-af", f"silencedetect=noise={noise_level}:d={min_duration}",
        "-f", "null", "-"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    starts = re.findall(r"silence_start: ([\d.]+)", result.stderr)
    ends = re.findall(r"silence_end: ([\d.]+)", result.stderr)
    return [(float(s), float(e)) for s, e in zip(starts, ends)]


def get_duration(input_file):
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return float(result.stdout.strip())


def get_fps(input_file):
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate",
        "-of", "default=noprint_wrappers=1:nokey=1",
        input_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    num, den = result.stdout.strip().split("/")
    return float(num) / float(den)


def normalize_to_cfr(input_file):
    """Convert variable frame rate to constant frame rate."""
    fps = get_fps(input_file)
    cfr_file = tempfile.NamedTemporaryFile(suffix=".mp4", delete=False).name

    print(f"Step 1: Normalizing to constant {fps:.2f} fps...")
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", input_file,
        "-vf", f"fps={fps:.6f}",
        "-c:v", "libx264", "-preset", "fast", "-crf", "16",
        "-c:a", "aac", "-b:a", "192k",
        "-video_track_timescale", "90000",
        cfr_file
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"CFR conversion error:\n{result.stderr[-500:]}")
        sys.exit(1)

    print("  Done.")
    return cfr_file


def build_atempo_chain(speed):
    filters = []
    remaining = float(speed)
    while remaining > 2.0:
        filters.append("atempo=2.0")
        remaining /= 2.0
    if remaining > 1.001:
        filters.append(f"atempo={remaining:.6f}")
    return ",".join(filters) if filters else None


def process_video(input_file, silent_speed=2.0, noise_level="-45dB", min_silence=1.0, margin=1.0):
    print(f"Analyzing: {input_file}")
    silences = detect_silence(input_file, noise_level, min_silence)
    total_duration = get_duration(input_file)

    print(f"Found {len(silences)} silent segments in {total_duration:.1f}s video")

    if not silences:
        print("No silence detected. Try raising --noise (e.g. -35dB) or lowering --min-silence (e.g. 0.5).")
        return

    # Step 1: normalize source to constant frame rate
    cfr_file = normalize_to_cfr(input_file)

    # Pre-adjust silence timestamps: shrink end by margin
    # so the margin naturally becomes part of the next speech segment
    adjusted_silences = []
    for s_start, s_end in silences:
        effective_end = s_end - margin
        if effective_end > s_start + 0.1:
            adjusted_silences.append((s_start, effective_end))

    # Build segment list (identical logic to the version that worked)
    segments = []
    current = 0.0

    for s_start, s_end in adjusted_silences:
        if s_start > current + 0.05:
            segments.append((current, s_start, 1.0))
        segments.append((s_start, s_end, float(silent_speed)))
        current = s_end

    if current < total_duration - 0.05:
        segments.append((current, total_duration, 1.0))

    segments = [(s, e, sp) for s, e, sp in segments if (e - s) >= 0.05]

    est_duration = sum((e - s) / sp for s, e, sp in segments)
    saved = total_duration - est_duration
    print(f"Output estimate: {est_duration:.1f}s (saving {saved:.1f}s)")

    # Step 2: apply speed changes on the CFR source
    print(f"Step 2: Applying speed changes ({len(segments)} segments)...")

    video_filters = []
    audio_filters = []

    for i, (start, end, speed) in enumerate(segments):
        if speed == 1.0:
            video_filters.append(
                f"[0:v]trim=start={start:.6f}:end={end:.6f},setpts=PTS-STARTPTS[v{i}]"
            )
            audio_filters.append(
                f"[0:a]atrim=start={start:.6f}:end={end:.6f},asetpts=PTS-STARTPTS[a{i}]"
            )
        else:
            pts = 1.0 / speed
            atempo = build_atempo_chain(speed)
            video_filters.append(
                f"[0:v]trim=start={start:.6f}:end={end:.6f},setpts={pts:.6f}*(PTS-STARTPTS)[v{i}]"
            )
            audio_filters.append(
                f"[0:a]atrim=start={start:.6f}:end={end:.6f},asetpts=PTS-STARTPTS,{atempo}[a{i}]"
            )

    concat_inputs = "".join(f"[v{i}][a{i}]" for i in range(len(segments)))
    n = len(segments)

    filtergraph = ";".join(video_filters + audio_filters)
    filtergraph += f";{concat_inputs}concat=n={n}:v=1:a=1[outv][outa]"

    name, _ = os.path.splitext(input_file)
    output_file = f"{name}_trimmed.mp4"

    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-i", cfr_file,
        "-filter_complex", filtergraph,
        "-map", "[outv]", "-map", "[outa]",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        output_file
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    # Clean up temp CFR file
    os.remove(cfr_file)

    if result.returncode != 0:
        print(f"FFmpeg error:\n{result.stderr[-500:]}")
        sys.exit(1)

    out_size = os.path.getsize(output_file) / (1024 * 1024)
    print(f"\nDone! Output: {output_file} ({out_size:.1f} MB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Speed up silent parts of a video, keep speech at normal speed."
    )
    parser.add_argument("input", help="Input video file")
    parser.add_argument(
        "--silent-speed", type=float, default=2.0,
        help="Speed multiplier for silent parts (default: 2)"
    )
    parser.add_argument(
        "--noise", default="-45dB",
        help="Noise floor for silence detection (default: -45dB)"
    )
    parser.add_argument(
        "--min-silence", type=float, default=1.0,
        help="Minimum silence duration in seconds (default: 1.0)"
    )
    parser.add_argument(
        "--margin", type=float, default=1.0,
        help="Seconds of normal-speed buffer before speech resumes (default: 1.0)"
    )

    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"Error: file not found: {args.input}")
        sys.exit(1)

    process_video(args.input, args.silent_speed, args.noise, args.min_silence, args.margin)
