# Parakeet v3: synthetic LT/EN check

2026-11-04, MacBook Pro M5 Max, 36 GB RAM, macOS 27.0.1. This is an isolated local experiment, not the app's current Parakeet Auto route. The direct native `ParakeetTranscriber` uses FluidAudio pin `5390df9752c8fc583596018360c5fd70d6fa6c75`, fresh decoder state and `language: nil` for each passage. It bypasses the Tiny language detector. The MLX paths use automatic language detection with mlx-whisper 0.4.3 and MLX 0.32.4. Models run sequentially in separate processes, with a resident model throughout each run. No production routing was changed.

The first FluidAudio model download plus load took 35.90 s; download bytes were not captured. The resulting cache occupies 480,068 KiB on disk, which is not RAM usage. FluidAudio model-repository revision was not captured; its Swift package revision is pinned. The MLX model revisions and setup are recorded below. Fresh-process load below uses already cached assets and a warm OS cache, not a first-install cold download. MLX loads and evaluates weights; subsequent first decode includes runtime initialization. The test runner used the existing compiled release objects and the pinned FluidAudio package.

## Audio and interpretation

All audio is synthetic macOS `say`: Lithuanian Ona, English Samantha; 16 kHz mono. Intended text is in `scripts/parakeet-benchmark.sh`. The technical sentence's intended wording is “Rytoj deployinam naują endpointą į stagingą ir patikrinam ar veikia prisijungimas.” TTS pronunciation is artificial, and written input is not a manually audited speech transcript. These are not human LT/EN or code-switch accuracy measurements.

The 33.424 s timeline concatenates complete LT1 (0–11.697 s), EN (12.197–20.638 s), and LT2 (21.138–32.924 s) utterances with 0.5 s gaps and a final 0.5 s silence. Separate utterances were each decoded twice, with the second set treated as warm, and the entire timeline decoded once. The timeline is a single decode with one detected Whisper language, not a live segmented pipeline. It tests whether text survives across switches, not switch timing or routing accuracy. A different earlier generated LT→EN→LT timeline clipped the beginning of the final LT passage in Parakeet; the repeated timeline below retained it. Synthetic TTS generation is variable, so exact output can differ.

## Measurements

RTF is decode wall seconds divided by audio duration, smaller is faster. Warm ranges cover the second decode of each of the four separate passages, not a percentile. CPU is process user + system time for the complete run including load and all nine decodes. RSS and footprint are OS process peaks reported by `/usr/bin/time -l`; they are not total model/system memory. MLX peak is `mlx.core.get_peak_memory()` across the run and is shown separately; it is a framework allocation metric on unified memory and must not be added to RSS. Core ML may use services outside the measured process, so its process RSS cannot establish total memory savings. No GPU time, ANE time, power, pressure or full-app usage was measured.

| Model | Cached process load | Warm passage time | Warm RTF | Whole timeline | Process CPU | Peak RSS | Peak footprint | MLX peak |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Parakeet v3 | 0.161 s | 0.071–0.082 s | 0.0067–0.0109 | 0.229 s | 1.12 s | 106 MB | 67 MB | n/a |
| Ąžuolas | 1.134 s | 0.610–0.904 s | 0.0712–0.0947 | 2.276 s | 8.91 s | 1,007 MB | 5,786 MB | 4,029 MB |
| large-v3 | 1.420 s | 0.590–0.871 s | 0.0699–0.0932 | 2.437 s | 8.81 s | 2,790 MB | 6,166 MB | 4,029 MB |

This single trial suggests direct Parakeet is substantially faster on these short synthetic utterances. It rendered the technical sample “deploi nam ... end painta”; large-v3 kept “endpointą”, Ąžuolas wrote “end pointą”. Ąžuolas rendered the English passage in Lithuanian. Large-v3 preserved it when separately decoded, but rendered the timeline's English passage as Lithuanian-like text after choosing LT for the entire timeline. Parakeet retained both switches in this particular timeline. None of these observations justify changing the app's router or removing its third-language protection. Validate against consented human speakers and inflected technical vocabulary before deciding.

## Transcripts

The text below is the exact first output per case. The second decode produced the same text for each individual passage in this run. Timeline text is included in full.

### lt1
- Parakeet v3: Šiandien aptarsime projekto eigą ir nuspręsime, kokius darbus reikia atlikti pirmiausia, rytoji komanda patikrins rezultatus ir parengs kitus žingsnius.
- Ąžuolas: šiandien aptarsime projekto eigą ir nuspręsime kokius darbus reikia atlikti pirmiausia rytoj komanda patikrins rezultatus ir parengs kitus žingsnius
- Whisper large-v3: Šiandien aptarsime projekto eigą ir nuspręsime, kokius darbus reikia atlikti pirmiausia. Rytoj komanda patikrins rezultatus ir parengs kitus žingsnius.

### en
- Parakeet v3: Today, we will review the project schedule and decide which tasks need attention first. Tomorrow, the team will check the results and prepare the next steps.
- Ąžuolas: šiandien mes išsivystysime projekto skaičių ir išsakysime kokios paslaugos reikia atsakingai pirm šiandieną
- Whisper large-v3: Today we will review the project schedule and decide which tasks need attention first. Tomorrow the team will check the results and prepare the next steps.

### lt2
- Parakeet v3: Labas rytas, norėčiau pasiteirauti, ar galime susitikti kitą savaitę, turime kelis klausimus apie paslaugas, kainas ir sutarties sąlygas.
- Ąžuolas: labas rytas norėčiau pasiteirauti ar galime susitikti kitą savaitę turime kelis klausimus apie paslaugas kainas ir sutarties sąlygas
- Whisper large-v3: Labas rytas, norėčiau pasiteirauti, ar galime susitikti kitą savaitę? Turime kelis klausimus apie paslaugas, kainas ir sutarties sąlygas.

### mixed
- Parakeet v3: Rytoj deploi nam naują end painta į staginga, ir patikrinam, ar veikia prisijungimas.
- Ąžuolas: rytoj deplojinam naują end pointą į stagingą ir patikrinam ar veikia prisijungimas
- Whisper large-v3: Rytoj deplojinam naują endpointą į stagingą ir patikrinam, ar veikia prisijungimas.

### timeline
- Parakeet v3: Šiandien aptarsime projekto eigą ir nuspręsime, kokius darbus reikia atlikti pirmiausia rytoji komanda patikrins rezultatus ir parengs kitus žingsnius. Today, we will review the project schedule and decide which tasks need attention first. Tomorrow the team will check the results and prepare the next steps. Labas rytas, norėčiau pasiteirauti, ar galime susitikti kitą savaitę. Turime kelis klausimus apie paslaugas, kainas ir sutarties sąlygas.
- Ąžuolas: šiandien aptarsime projekto eigą ir nuspręsime kokius darbus reikia atlikti pirmiausia rytoj komanda patikrins rezultatus ir parengs kitus žingsnius šiandien mes išreikšime projekto planą ir išsakysime kuriuos klausimus reikia atidžiau pirmas rytoj komanda pasižiūrės rezultatus ir pripažins kitus stepus labas rytas norėčiau pasiteirauti ar galime susitikti kitą savaitę turime kelis klausimus apie paslaugas kainas ir sutarties sąlygas
- Whisper large-v3: Šiandien aptarsime projekto įgą ir nuspręsime, kokius darbus reikia atlikti pirmiausia. Rytoj komanda patikrins rezultatus ir parengs kitus žingsnius. Dabar mes atsiprašėme projektų skedulą ir atsiprašėme, kokie pasaulyje reikia atsiprašyti. Dabar komanda atsiprašėme rezultatų ir atsiprašėme kitus pasaulyjus. Labas rytas, norėčiau pasiteirauti, ar galime susitikti kitą savaitę. Turime kelis klausimus apie paslaugas, kainas ir sutarties sąlygas.

## Reproduce

Run on an Apple silicon Mac with the Ona and Samantha macOS voices installed, `ffmpeg`, Xcode command line tools, and the app's release build and FluidAudio v3 model cache already present. Build the app using the repository Makefile before running if release artifacts are missing. The script checks the arm64 artifacts before generating audio.

Provide a local Python environment with `mlx` and `mlx-whisper` installed (the recorded run used MLX 0.32.4 and mlx-whisper 0.4.3), and two already downloaded MLX model directories. The recorded Ąžuolas model was converted to float16 using the [MLX Whisper converter](https://github.com/ml-explore/mlx-examples/blob/main/whisper/convert.py) from `akisviete/azuolas-whisper-lt`, revision `ec413b4f91edfd1eb935ded59407cc699f180eba`, `original/best_model.pt`; its `weights.safetensors` links to the converted `model.safetensors`. The English model was `mlx-community/whisper-large-v3-mlx`, revision `49e6aa286ad60c14352c404340ded53710378a11`. Each directory needs `config.json` and either `weights.safetensors` or `weights.npz`.

```sh
SAKVIRO_BENCH_PYTHON=/absolute/path/to/python \
SAKVIRO_AZUOLAS_MODEL=/absolute/path/to/azuolas \
SAKVIRO_ENGLISH_MODEL=/absolute/path/to/english-model \
scripts/parakeet-benchmark.sh /absolute/path/to/output
```

The default paths are `../.venv/bin/python`, `../models/azuolas-whisper-lt-mlx`, and the English revision in the current user's Hugging Face cache. The script uses only local model paths, writes generated audio and logs to the output directory, and does not download models. Do not compare runs while other inference is active.
