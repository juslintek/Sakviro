#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ffmpeg -v error -f lavfi -i 'color=c=blue:s=64x64:r=10:d=1.4' -c:v libx264 -pix_fmt yuv420p "$work/input.mp4"
ffmpeg -v error -f lavfi -i 'sine=frequency=440:duration=1.4' -c:a pcm_s16le "$work/system.caf"
ffmpeg -v error -f lavfi -i 'sine=frequency=880:duration=1.4' -c:a pcm_s16le "$work/mic.caf"
swiftc -parse-as-library Parrot/Services/VideoCaptureService.swift tests/video-mux/Check.swift -o "$work/check"
"$work/check" "$work/input.mp4" "$work/system.caf" "$work/mic.caf" "$work/output.mp4"
ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of default=noprint_wrappers=1:nokey=1 "$work/output.mp4" > "$work/video-start"
python3 - "$work/video-start" <<'PY'
import sys
start = float(open(sys.argv[1]).read())
assert .15 <= start <= .25, f'video offset lost: {start}'
print('PASS video offset')
PY
ffmpeg -v error -i "$work/output.mp4" -ac 1 -ar 8000 -f f32le "$work/audio.raw"
python3 - "$work/audio.raw" <<'PY'
import math, struct, sys
raw = open(sys.argv[1], 'rb').read()
samples = struct.unpack('<%df' % (len(raw) // 4), raw)
for frequency in (440, 880):
    real = sum(v * math.cos(2 * math.pi * frequency * i / 8000) for i, v in enumerate(samples)) / len(samples)
    imaginary = sum(v * math.sin(2 * math.pi * frequency * i / 8000) for i, v in enumerate(samples)) / len(samples)
    assert math.hypot(real, imaginary) > .005, f'missing {frequency} Hz audio'
print('PASS both synthetic audio sources are audible')
PY
