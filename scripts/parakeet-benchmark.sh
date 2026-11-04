#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?Usage: scripts/parakeet-benchmark.sh OUTPUT_DIRECTORY}
python=${SAKVIRO_BENCH_PYTHON:-../.venv/bin/python}
azuolas=${SAKVIRO_AZUOLAS_MODEL:-../models/azuolas-whisper-lt-mlx}
english=${SAKVIRO_ENGLISH_MODEL:-$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-mlx/snapshots/49e6aa286ad60c14352c404340ded53710378a11}
cache="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
fluid=.build/checkouts/FluidAudio
artifacts=.build/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64
objects=.build/out/Intermediates.noindex/FluidAudio.build/Release
fail() { echo "Benchmark preflight: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail "provide exactly one output directory"
[ "$(uname -m)" = arm64 ] || fail "this benchmark requires arm64 release artifacts on an Apple silicon Mac"
for command in say ffmpeg swiftc lipo; do
    command -v "$command" >/dev/null || fail "missing command: $command"
done
voices=$(say -v '?') || fail "cannot list macOS voices"
for voice in Ona Samantha; do
    printf '%s\n' "$voices" | awk '{print $1}' | /usr/bin/grep -Fx "$voice" >/dev/null || fail "missing macOS voice: $voice"
done
[ -x "$python" ] || fail "Python is not executable: $python (set SAKVIRO_BENCH_PYTHON)"
"$python" -c 'import mlx.core, mlx_whisper' || fail "Python needs mlx and mlx-whisper installed"
for model in "$azuolas" "$english"; do
    [ -f "$model/config.json" ] || fail "missing model config: $model/config.json"
    [ -f "$model/weights.safetensors" ] || [ -f "$model/weights.npz" ] || fail "missing model weights in: $model"
done
[ -d "$cache" ] || fail "FluidAudio v3 model cache is missing: $cache"
for path in .build/release/FluidAudio.o "$objects/FastClusterWrapper-t.build/Objects-normal/arm64/FastClusterWrapper.o" "$objects/MachTaskSelfWrapper-t.build/Objects-normal/arm64/MachTaskSelf.o" "$artifacts/libtext_processing_rs.a"; do
    [ -f "$path" ] || fail "missing release artifact: $path; build the release first"
    lipo -verify_arch arm64 "$path" || fail "release artifact does not contain arm64: $path"
done
[ -d "$fluid/Sources/FastClusterWrapper/include" ] || fail "FluidAudio checkout is missing"
[ -d "$fluid/Sources/MachTaskSelfWrapper/include" ] || fail "FluidAudio checkout is missing"
[ -d "$artifacts/Headers" ] || fail "NemoTextProcessing headers are missing"
[ -e .build/release/FluidAudio.swiftmodule ] || [ -e .build/release/Modules/FluidAudio.swiftmodule ] || fail "release FluidAudio Swift module is missing"
mkdir -p "$output"
output=$(cd "$output" && pwd)
say -v Ona -o "$output/lt1.aiff" 'Šiandien aptarsime projekto eigą ir nuspręsime, kokius darbus reikia atlikti pirmiausia. Rytoj komanda patikrins rezultatus ir parengs kitus žingsnius.'
say -v Samantha -o "$output/en.aiff" 'Today we will review the project schedule and decide which tasks need attention first. Tomorrow the team will check the results and prepare the next steps.'
say -v Ona -o "$output/lt2.aiff" 'Labas rytas, norėčiau pasiteirauti, ar galime susitikti kitą savaitę. Turime kelis klausimus apie paslaugas, kainas ir sutarties sąlygas.'
say -v Ona -o "$output/mixed.aiff" 'Rytoj deployinam naują endpointą į stagingą ir patikrinam ar veikia prisijungimas.'
for name in lt1 en lt2 mixed; do
    ffmpeg -hide_banner -loglevel error -y -i "$output/$name.aiff" -ar 16000 -ac 1 "$output/$name.wav"
done
"$python" - "$output" <<'PY'
import sys, wave
from pathlib import Path
root = Path(sys.argv[1])
with wave.open(str(root / 'timeline.wav'), 'wb') as dest:
    dest.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
    position = 0
    for name in ('lt1', 'en', 'lt2'):
        with wave.open(str(root / (name + '.wav')), 'rb') as audio:
            assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 16000)
            duration = audio.getnframes() / 16000
            print(f'{name}: {position:.3f}–{position + duration:.3f}s')
            dest.writeframes(audio.readframes(audio.getnframes()))
        dest.writeframes(bytes(16000))
        position += duration + 0.5
PY
swiftc -parse-as-library -O -I .build/release -I "$fluid/Sources/FastClusterWrapper/include" -I "$fluid/Sources/MachTaskSelfWrapper/include" -I "$artifacts/Headers" scripts/parakeet-benchmark.swift Parrot/Services/ParakeetTranscriber.swift .build/release/FluidAudio.o "$objects/FastClusterWrapper-t.build/Objects-normal/arm64/FastClusterWrapper.o" "$objects/MachTaskSelfWrapper-t.build/Objects-normal/arm64/MachTaskSelf.o" "$artifacts/libtext_processing_rs.a" -lc++ -o "$output/parakeet"
/usr/bin/time -l "$output/parakeet" "$output" > "$output/parakeet.log" 2>&1
/usr/bin/time -l "$python" scripts/parakeet-benchmark-mlx.py "$azuolas" "$output" > "$output/azuolas.log" 2>&1
/usr/bin/time -l "$python" scripts/parakeet-benchmark-mlx.py "$english" "$output" > "$output/large-v3.log" 2>&1
