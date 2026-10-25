#!/usr/bin/env python3
"""Run an already-built idle benchmark in private state; leave the user app running."""
import argparse, json, os, pathlib, subprocess, time
p = argparse.ArgumentParser()
p.add_argument('--app', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
out = pathlib.Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, VG_BENCH_STATE_DIR=str(out/'state'), VG_IDLE_SECONDS='120', VG_SETTLE_SECONDS='20')
app = pathlib.Path(a.app).resolve()/'Contents/MacOS/VibeDeck'
samples = []
with (out/'raw.log').open('w') as log:
    child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=subprocess.STDOUT)
    begin = time.monotonic()
    while child.poll() is None and time.monotonic()-begin < 190:
        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(child.pid)], capture_output=True, text=True)
        if result.stdout.strip():
            samples.append({'elapsed': time.monotonic()-begin, 'rss_mb': int(result.stdout.strip())/1024})
        time.sleep(1)
    if child.poll() is None:
        child.terminate()  # Only this wrapper's child, never another VibeDeck instance.
        child.wait(timeout=10)
    result = {'app': str(app), 'exit_code': child.returncode, 'rss_samples': samples}
    for line in (out/'raw.log').read_text().splitlines():
        if line.startswith('VG_END '):
            result['idle'] = json.loads(line[7:])
    stable = [v['rss_mb'] for v in samples if v['elapsed'] >= 20]
    result['rss_mean_mb'] = sum(stable)/len(stable) if stable else None
    result['rss_max_mb'] = max(stable) if stable else None
    (out/'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('rss_samples','idle')}, indent=2))
    print(json.dumps({k:v for k,v in result.get('idle',{}).items() if k != 'samples'}, indent=2))
    if child.returncode or not result.get('idle',{}).get('valid'):
        raise SystemExit(1)
