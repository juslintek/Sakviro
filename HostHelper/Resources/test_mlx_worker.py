import json
import os
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as model:
    for name in ("config.json", "weights.safetensors"):
        open(os.path.join(model, name), "w").close()
    worker = os.path.join(os.path.dirname(__file__), "mlx_worker.py")
    requests = [
        {"action": "bad", "model": model},
        {"action": "transcribe", "model": model, "sampleRate": 8000, "pcm": "AAAAAA=="},
        {"action": "transcribe", "model": model, "sampleRate": 16000, "pcm": "!!!!"},
        {"action": "transcribe", "model": model, "sampleRate": 16000, "pcm": "AACAfw=="},
    ]
    run = subprocess.run([sys.executable, worker], input="".join(json.dumps(r) + "\n" for r in requests),
                         text=True, capture_output=True, check=True)
    responses = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(responses) == len(requests)
    assert all(response["ok"] is False and response["error"] for response in responses)
    assert "sample" in responses[-1]["error"].lower()
print("MLX worker validation passed")
