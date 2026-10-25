#!/usr/bin/env python3
"""One bounded stop/restore window for prepared, isolated VibeDeck benchmarks.

All builds and tests must finish first. This runner never rebuilds or installs.
Raw output contains private usage data; keep it in the mode-0700 output directory.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True)
parser.add_argument('--candidate', required=True)
parser.add_argument('--normal-app', required=True)
parser.add_argument('--expected-user-pid', type=int, required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = pathlib.Path(args.output).resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
normal = str(pathlib.Path(args.normal_app).resolve() / 'Contents/MacOS/VibeDeck')
receipt = {'began_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'normal_path': normal, 'phases': [], 'comparisons': []}
child = None
stopped = False
owned_children = {}
comparison_processes = []


def rows():
    result = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,lstart=,command='], text=True).splitlines():
        fields = line.strip().split(None, 8)
        if len(fields) == 9:
            result[int(fields[0])] = {'ppid': int(fields[1]), 'pgid': int(fields[2]),
                                     'identity': (' '.join(fields[3:8]), fields[8]), 'command': fields[8]}
    return result


def exact(path):
    return [pid for pid, row in rows().items() if row['command'] == path]


def fingerprints():
    result = {}
    config = pathlib.Path.home() / '.config/vibedeck'
    for name in ('prices.json', 'quota-samples.json', 'usage-daily.json'):
        path = config / name
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else 'absent'
    path = pathlib.Path.home() / '.ssh/known_hosts'
    result['known_hosts'] = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else 'absent'
    try:
        raw = subprocess.check_output(['defaults', 'export', 'io.github.xixilys.vibedeck', '-'], stderr=subprocess.DEVNULL)
        result['defaults'] = hashlib.sha256(plistlib.dumps(plistlib.loads(raw), fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest()
    except subprocess.CalledProcessError:
        result['defaults'] = 'absent'
    return result


def save():
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))


def observe_children():
    if child is None:
        return
    current = rows()
    found = {child.pid}
    for _ in range(8):
        found |= {pid for pid, row in current.items() if row['ppid'] in found}
    found |= {pid for pid, row in current.items() if row['pgid'] == child.pid}
    for pid in found - {child.pid}:
        if pid in current:
            owned_children[pid] = current[pid]['identity']


def stop_child():
    global child
    observe_children()
    if child is not None and child.poll() is None:
        child.terminate()
        child.wait(timeout=10)
    current = rows()
    remaining = {pid for pid, identity in owned_children.items()
                 if pid in current and current[pid]['identity'] == identity}
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 8
    while remaining and time.monotonic() < deadline:
        current = rows()
        remaining = {pid for pid in remaining if pid in current and current[pid]['identity'] == owned_children[pid]}
        time.sleep(.1)
    if remaining:
        raise RuntimeError('Own collector descendants survived SIGTERM')
    owned_children.clear()
    child = None


def records(path, tag):
    return [json.loads(line.partition(' ')[2]) for line in path.read_text().splitlines() if line.startswith(tag + ' ')]


def alarm(number, frame):
    raise InterruptedError('Deadline or signal: ' + str(number))


for number in (signal.SIGALRM, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, alarm)
try:
    for binary in (args.baseline, args.candidate, normal):
        if not pathlib.Path(binary).is_file():
            raise RuntimeError('Prepared binary missing: ' + binary)
    old = exact(normal)
    if old != [args.expected_user_pid]:
        raise RuntimeError('Original PID/path changed; not stopping: ' + str(old))
    uid = int(subprocess.check_output(['ps', '-p', str(old[0]), '-o', 'uid='], text=True))
    if uid != os.getuid():
        raise RuntimeError('User instance UID differs')
    other = [(pid, row['command']) for pid, row in rows().items()
             if row['command'].endswith('/Contents/MacOS/VibeDeck') and row['command'] != normal]
    if other:
        raise RuntimeError('Another app/benchmark is running: ' + str(other))
    receipt['original_pid'] = old[0]
    receipt['original_uid'] = uid
    receipt['fingerprints_before_stop'] = fingerprints()
    receipt['downtime_start'] = time.monotonic()
    signal.alarm(1080)  # 18 minutes, leaves 2 minutes for restoration.
    os.kill(old[0], signal.SIGTERM)
    stopped = True
    for _ in range(100):
        if not exact(normal):
            break
        time.sleep(.1)
    else:
        raise RuntimeError('Original app did not stop gracefully')
    receipt['fingerprints_after_stop'] = fingerprints()
    save()
    for round_number in range(1, 4):
        for label, binary in [('baseline', args.baseline), ('candidate', args.candidate)]:
            if exact(normal):
                raise RuntimeError('User app restarted during benchmark')
            name = f'{label}-{round_number}'
            state = out / (name + '-state')
            state.mkdir()
            env = os.environ.copy()
            env.update(VG_BENCH_STATE_DIR=str(state), VG_IDLE_SECONDS='120', VG_SETTLE_SECONDS='20')
            path = out / (name + '.log')
            with path.open('w') as log:
                child = subprocess.Popen([binary], stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
                started = time.monotonic()
                phase = {'label': label, 'round': round_number, 'pid': child.pid, 'binary': binary,
                         'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
                receipt['phases'].append(phase)
                save()
                while child.poll() is None:
                    observe_children()
                    if time.monotonic() - started > 175:
                        raise TimeoutError('Benchmark deadline')
                    time.sleep(1)
                phase['exit_code'] = child.returncode
            stop_child()
            windows = records(path, 'VG_END')
            if phase['exit_code'] != 0 or len(windows) != 1 or not windows[0]['valid']:
                raise RuntimeError('Invalid closed-menu window: ' + name)
            phase['window'] = windows[0]
            save()
            print(name, 'complete', round(windows[0]['sum_pct'], 4), flush=True)
    # Same-start snapshots, with no app timers/history/remote SSH, outside CPU measurement.
    for pair in range(1, 4):
        processes = []
        for label, binary in [('baseline', args.baseline), ('candidate', args.candidate)]:
            state = out / f'compare-{pair}-{label}-state'
            state.mkdir()
            env = os.environ.copy()
            env.update(VG_BENCH_STATE_DIR=str(state), VG_COMPARE_ONLY='1')
            log = (out / f'compare-{pair}-{label}.log').open('w')
            process = subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append((label, process, log))
            comparison_processes.append(process)
        for label, process, log in processes:
            try:
                code = process.wait(timeout=25)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                log.close()
            reports = records(out / f'compare-{pair}-{label}.log', 'VG_REPORT')
            if code or len(reports) != 1:
                raise RuntimeError('Snapshot comparison failed')
            receipt['comparisons'].append({'pair': pair, 'label': label, 'report': reports[0]})
    receipt['outcome'] = 'succeeded'
except BaseException as error:
    receipt['outcome'] = 'failed'
    receipt['error'] = repr(error)
    print('FAIL', repr(error), flush=True)
finally:
    # Restoration must not be skipped because a fingerprint read or benchmark cleanup failed.
    signal.alarm(0)
    for process in comparison_processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                receipt['comparison_cleanup_error'] = 'Own snapshot process survived SIGTERM'
                receipt['outcome'] = 'failed'
    try:
        stop_child()
    except BaseException as error:
        receipt['cleanup_error'] = repr(error)
        receipt['outcome'] = 'failed'
    if stopped:
        try:
            receipt['fingerprints_before_restore'] = fingerprints()
            receipt['five_fingerprints_unchanged'] = receipt['fingerprints_after_stop'] == receipt['fingerprints_before_restore']
        except BaseException as error:
            receipt['fingerprint_error'] = repr(error)
            receipt['outcome'] = 'failed'
        try:
            if not exact(normal):
                subprocess.run(['open', args.normal_app], check=True)
            for _ in range(100):
                if exact(normal):
                    break
                time.sleep(.1)
            receipt['restored_pids'] = exact(normal)
            receipt['downtime_seconds'] = time.monotonic() - receipt['downtime_start']
            receipt['restored_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            if len(receipt['restored_pids']) != 1 or receipt['downtime_seconds'] > 1200:
                raise RuntimeError('Restoration PID missing/ambiguous or downtime over 20min')
        except BaseException as error:
            receipt['restore_error'] = repr(error)
            receipt['outcome'] = 'failed'
    save()
    print(json.dumps({k: receipt.get(k) for k in ('outcome', 'error', 'restored_pids', 'downtime_seconds', 'five_fingerprints_unchanged', 'restore_error')}), flush=True)
raise SystemExit(0 if receipt['outcome'] == 'succeeded' else 1)
