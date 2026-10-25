#!/usr/bin/env python3
"""Build/run both real UsageHistory versions against an immutable private fixture.
Private logs, usage snapshots and binaries stay in /tmp. Reports contain only aggregate diffs.
"""
import argparse, json, os, pathlib, shutil, sqlite3, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]

def run(argv, **kw):
    return subprocess.run(list(map(str, argv)), check=True, **kw)

def prepare(dest):
    if dest.exists() and any(dest.iterdir()): raise SystemExit('Fixture directory must be empty; use a fresh /tmp directory')
    dest.mkdir(parents=True, exist_ok=True)
    source = pathlib.Path.home()
    logs = dest/'logs'
    for rel in ('.claude/projects', '.config/claude/projects', '.codex/sessions', '.codex/archived_sessions'):
        src=source/rel; dst=logs/rel
        if src.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            run(['/bin/cp','-cR',src,dst])
    config=logs/'.config/vibedeck'; config.mkdir(parents=True,exist_ok=True)
    for name in ('prices.json','api-calls.jsonl'):
        if (source/'.config/vibedeck'/name).exists(): shutil.copy2(source/'.config/vibedeck'/name,config/name)
    shutil.copy2(source/'.config/vibedeck/usage-daily.json',dest/'seed.json')
    db=source/'.local/share/opencode/opencode.db'
    if db.exists():
        target=logs/'.local/share/opencode/opencode.db'; target.parent.mkdir(parents=True,exist_ok=True)
        with sqlite3.connect(f'file:{db}?mode=ro',uri=True,timeout=30) as src, sqlite3.connect(target) as dst: src.backup(dst)
    proc=subprocess.run(['defaults','read','io.github.xixilys.vibedeck','remoteHosts'],capture_output=True,text=True)
    metadata=dict(source_home=str(source),opencode_db=str(db),remote_hosts=proc.stdout.strip() if proc.returncode==0 else '',created_at=time.time(),clock=time.time())
    (dest/'fixture.json').write_text(json.dumps(metadata,indent=2))
    os.chmod(dest,0o700)
    print(dest)

def build(label, ref, work):
    stage=work/(label+'-build'); sources=stage/'Sources'; sources.mkdir(parents=True,exist_ok=True)
    names=sorted(p.name for p in (ROOT/'Sources').glob('*.swift') if p.name!='main.swift')
    for name in names:
        text=subprocess.check_output(['git','show',f'{ref}:Sources/{name}'],cwd=ROOT,text=True) if ref else (ROOT/'Sources'/name).read_text()
        if name=='UsageHistory.swift':
            text=text.replace('private func scan(forceRemote: Bool = false) {','private func scan(forceRemote: Bool = false) {\n        let probeStart = HistoryProbe.cpu(); defer { HistoryProbe.noteScan(probeStart) }')
            text=text.replace('        loaded = true', '        loaded = true\n        let loadStart = ProcessInfo.processInfo.systemUptime; defer { HistoryProbe.loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart }')
            # Real logs are read through stable APFS clones. Cache keys retain their original identity.
            text=text.replace('FileManager.default.fileExists(atPath: opencodeDB)','FileManager.default.fileExists(atPath: HistoryProbe.physical(opencodeDB))')
            text=text.replace('OpenCodeUsage.read(dbPath: opencodeDB)','OpenCodeUsage.read(dbPath: HistoryProbe.physical(opencodeDB))')
            text=text.replace('attributesOfItem(atPath: path)','attributesOfItem(atPath: HistoryProbe.physical(path))')
            text=text.replace('FileHandle(forReadingFrom: URL(fileURLWithPath: path))','FileHandle(forReadingFrom: URL(fileURLWithPath: HistoryProbe.physical(path)))')
            text=text.replace('fm.fileExists(atPath: path)','fm.fileExists(atPath: HistoryProbe.physical(path))')
            text=text.replace('fm.fileExists(atPath: other)','fm.fileExists(atPath: HistoryProbe.physical(other))')
            text=text.replace('return result.sorted { $0.path < $1.path }','return result.map { (path: HistoryProbe.logical($0.path), source: $0.source) }.sorted { $0.path < $1.path }')
            # Comparison freezes the accounting clock only; benchmark uses the unmodified wall clock.
            text=text.replace('let now = Date()','let now = (HistoryProbe.env["VG_HISTORY_FIXED_CLOCK"] == "1" ? Date(timeIntervalSince1970: HistoryProbe.metadata["clock"] as! Double) : Date())')
            text=text.replace('let now = Date().timeIntervalSince1970','let now = HistoryProbe.env["VG_HISTORY_FIXED_CLOCK"] == "1" ? (HistoryProbe.metadata["clock"] as! Double) : Date().timeIntervalSince1970')
            text=text.replace('        let cliCost = result.costBySource','        HistoryProbe.hourly = hourly\n        HistoryProbe.deviceHourly = deviceHourly\n        let cliCost = result.costBySource')
        (sources/name).write_text(text)
    app=stage/'History.app'; resources=app/'Contents/Resources'; resources.mkdir(parents=True,exist_ok=True)
    (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'Resources/Info.plist',app/'Contents/Info.plist')
    for name in ('prices.builtin.json','vibedeck-collector.py'): shutil.copy2(ROOT/'Resources'/name,resources/name)
    binary=app/'Contents/MacOS/History'
    run(['swiftc','-O','-whole-module-optimization','-parse-as-library','-target','arm64-apple-macosx14.0','-framework','Cocoa','-framework','SwiftUI','-framework','ServiceManagement','-framework','UserNotifications','-lsqlite3',*[sources/n for n in names],ROOT/'tools/history-compare.swift','-o',binary])
    print(binary)

def execute(label,work,seconds,warm,live):
    out=work/label; out.mkdir(parents=True,exist_ok=True)
    cache=out/'usage-daily.json'
    if not warm: shutil.copy2(work/'seed.json',cache)
    env=dict(os.environ,HOME=str(out),CFFIXED_USER_HOME=str(out),VG_HISTORY_FIXTURE=str(work),VG_HISTORY_OUTPUT=str(out),VG_HISTORY_SECONDS=str(seconds),VG_HISTORY_FIXED_CLOCK='0' if seconds else '1')
    argv=[work/(label.split('-')[0]+'-build/History.app/Contents/MacOS/History')]
    if not live: argv+=['--selftest'] # Production explicitly skips SSH in selftests.
    run(argv,env=env)

def compare(before, after, report):
    a=json.loads((before/'snapshot.json').read_text()); b=json.loads((after/'snapshot.json').read_text())
    ignored={'isScanning','processedFiles','totalFiles','capturedAt','sourceNotes','error'}
    for x in (a,b):
        for key in ignored: x['snapshot'].pop(key,None)
    rows=[]; failures=[]
    def walk(x,y,path,stats):
        stats['checks']+=1
        if isinstance(x,dict) and isinstance(y,dict):
            if x.keys()!=y.keys(): failures.append((path,'keys differ'))
            for k in sorted(x.keys() & y.keys()): walk(x[k],y[k],path+'.'+k,stats)
        elif isinstance(x,list) and isinstance(y,list):
            if len(x)!=len(y): failures.append((path,'array length differs'))
            for i,(v,w) in enumerate(zip(x,y)): walk(v,w,path+f'[{i}]',stats)
        elif isinstance(x,(float,int)) and not isinstance(x,bool) and isinstance(y,(float,int)) and not isinstance(y,bool):
            delta=abs(x-y); stats['max_delta']=max(stats['max_delta'],delta)
            tolerance=0.01 if isinstance(x,float) or isinstance(y,float) else 0
            if delta>tolerance: failures.append((path,f'delta={delta:.12g}, before={x}, after={y}'))
        elif x!=y: failures.append((path,f'{x!r} != {y!r}'))
    groups=[('snapshot.'+key,a['snapshot'].get(key),b['snapshot'].get(key)) for key in sorted(a['snapshot'].keys() | b['snapshot'].keys())]
    groups += [(key,a.get(key),b.get(key)) for key in ('hourly','deviceHourly')]
    for name,x,y in groups:
        start=len(failures); stats=dict(checks=0,max_delta=0); walk(x,y,name,stats)
        rows.append((name,'PASS' if len(failures)==start else 'FAIL',stats['checks'],stats['max_delta']))
    status='PASS' if not failures else 'FAIL'
    text=f'# 历史缓存等价性：{status}\n\n输入为同一份真实缓存副本、APFS 日志副本和只读 SQLite 备份；两版固定同一 now。SSH 在这个确定性比较中跳过，远端历史仍来自同一份真实缓存，远端重拉另测。token/条数/会话数零容差，金额绝对差 ≤0.01；排除扫描进度、采集时间、错误与来源说明。\n\n| 字段 | 结果 | 检查数 | 最大差 |\n| --- | --- | ---: | ---: |\n'
    text+=''.join(f'| {n} | {s} | {c} | {d:.12g} |\n' for n,s,c,d in rows)
    if failures: text+='\n## 不一致\n\n'+''.join(f'- `{p}`: {v}\n' for p,v in failures[:100])
    report.parent.mkdir(parents=True,exist_ok=True); report.write_text(text)
    report.with_suffix('.json').write_text(json.dumps(dict(status=status,groups=rows,failures=failures),indent=2))
    print(status, 'checks',sum(r[2] for r in rows),'failures',len(failures))
    return not failures

if __name__=='__main__':
    p=argparse.ArgumentParser(); subs=p.add_subparsers(dest='command',required=True)
    q=subs.add_parser('prepare'); q.add_argument('--work',type=pathlib.Path,required=True)
    q=subs.add_parser('build'); q.add_argument('--work',type=pathlib.Path,required=True); q.add_argument('--label',required=True); q.add_argument('--ref')
    q=subs.add_parser('run'); q.add_argument('--work',type=pathlib.Path,required=True); q.add_argument('--label',required=True); q.add_argument('--seconds',type=float,default=0); q.add_argument('--warm',action='store_true'); q.add_argument('--live',action='store_true')
    q=subs.add_parser('compare'); q.add_argument('--before',type=pathlib.Path,required=True); q.add_argument('--after',type=pathlib.Path,required=True); q.add_argument('--report',type=pathlib.Path,required=True)
    a=p.parse_args()
    if hasattr(a,'work'):
        a.work=a.work.resolve()
        if pathlib.Path('/tmp').resolve() not in a.work.parents: raise SystemExit('--work must be a private directory under /tmp')
    if hasattr(a,'label') and (not a.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in a.label)):
        raise SystemExit('--label must contain only letters, digits, underscores and hyphens')
    if a.command=='prepare': prepare(a.work)
    elif a.command=='build': build(a.label,a.ref,a.work)
    elif a.command=='run': execute(a.label,a.work,a.seconds,a.warm,a.live)
    else: raise SystemExit(0 if compare(a.before,a.after,a.report) else 1)
