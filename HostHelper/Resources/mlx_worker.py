import base64
import contextlib
import json
import math
import os
import struct
import sys

try:
    import numpy as np
except ImportError:
    np = None

MAX_SAMPLES = 16000 * 30
VALIDATED_MODELS = set()


def validate_model_dir(path):
    if not isinstance(path, str) or not os.path.isabs(path):
        raise ValueError("Choose a local MLX model folder")
    if path in VALIDATED_MODELS:
        return
    if not os.path.isdir(path):
        raise ValueError("Choose a local MLX model folder")
    if not os.path.isfile(os.path.join(path, "config.json")) or not any(
        os.path.isfile(os.path.join(path, name)) for name in ("weights.safetensors", "weights.npz")
    ):
        raise ValueError("MLX model folder is missing config or weights")
    VALIDATED_MODELS.add(path)


def handle(request):
    action = request.get("action")
    if action not in ("load", "transcribe"):
        raise ValueError("Unknown MLX action")
    path = request.get("model")
    validate_model_dir(path)
    if action == "transcribe":
        if request.get("sampleRate") != 16000:
            raise ValueError("Audio must be 16 kHz mono")
        encoded = request.get("pcm")
        if not isinstance(encoded, str) or len(encoded) > MAX_SAMPLES * 8:
            raise ValueError("Invalid PCM length")
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) % 4 or len(raw) > MAX_SAMPLES * 4:
            raise ValueError("Invalid PCM length")
        if np is not None:
            samples = np.frombuffer(raw, dtype="<f4")
            if not bool(np.all(np.isfinite(samples))) or (samples.size > 0 and float(np.max(np.abs(samples))) > 1.0):
                raise ValueError("Invalid PCM sample")
            audio = np.array(samples, dtype=np.float32, copy=True)
        else:
            samples = struct.unpack(f"<{len(raw) // 4}f", raw)
            if not all(math.isfinite(value) and abs(value) <= 1 for value in samples):
                raise ValueError("Invalid PCM sample")
            audio = samples
        language = request.get("language")
        if language is not None and (not isinstance(language, str) or not language.isalpha() or len(language) > 5):
            raise ValueError("Invalid language")
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder, transcribe
        if ModelHolder.model_path != path:
            ModelHolder.model = None
            ModelHolder.model_path = None
            mx.clear_cache()
        if action == "load":
            ModelHolder.get_model(path, mx.float16)
            return {"ok": True}
        if np is None:
            import numpy as _np
            audio = _np.asarray(audio, dtype=_np.float32)
        result = transcribe(audio, path_or_hf_repo=path,
                            language=language, verbose=None, fp16=True)
    raw_segments = result.get("segments") or []
    segments = [
        {
            "start": float(s.get("start", 0.0)),
            "end": float(s.get("end", 0.0)),
            "text": str(s.get("text", "")).strip(),
        }
        for s in raw_segments
        if str(s.get("text", "")).strip()
    ]
    return {"ok": True, "text": result["text"], "segments": segments}


for line in sys.stdin:
    try:
        request = json.loads(line)
        response = handle(request)
    except Exception as error:
        response = {"ok": False, "error": str(error)}
    print(json.dumps(response, ensure_ascii=False), flush=True)
