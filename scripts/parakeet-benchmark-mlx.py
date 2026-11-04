import sys, time, json, resource, wave
from pathlib import Path
import mlx.core as mx
from mlx_whisper.transcribe import ModelHolder, transcribe
model, directory = sys.argv[1:]
start = time.perf_counter()
ModelHolder.get_model(model, mx.float16)
mx.eval(ModelHolder.model.parameters())
print(json.dumps({'load_seconds': time.perf_counter()-start}), flush=True)
for name in ['lt1','en','lt2','mixed','lt1','en','lt2','mixed','timeline']:
    path = str(Path(directory) / (name + '.wav'))
    with wave.open(path) as w: duration = w.getnframes()/w.getframerate()
    start = time.perf_counter()
    decoded = transcribe(path, path_or_hf_repo=model, verbose=None)
    seconds = time.perf_counter()-start
    print(json.dumps({'case':name,'duration':duration,'seconds':seconds,'rtf':seconds/duration,'language':decoded['language'],'text':decoded['text'].strip(),'gpu_peak_bytes':mx.get_peak_memory()}), flush=True)
print(json.dumps({'user_cpu_seconds':resource.getrusage(resource.RUSAGE_SELF).ru_utime,'system_cpu_seconds':resource.getrusage(resource.RUSAGE_SELF).ru_stime,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}),flush=True)
