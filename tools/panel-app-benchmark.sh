#!/bin/bash
# Build only. No build.sh, collector launch, or user-instance termination.
# Usage: panel-app-benchmark.sh --source-dir DIR --output-dir DIR [--typecheck]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR=Sources; OUTPUT_DIR=review-shots/performance/app-current; MODE=build
while [[ $# -gt 0 ]]; do
case "$1" in
--source-dir) SOURCE_DIR="$2"; shift 2;;
--output-dir) OUTPUT_DIR="$2"; shift 2;;
--build-only) shift;;
--typecheck) MODE=typecheck; shift;;
*) echo "Unknown argument $1" >&2; exit 2;; esac
done
mkdir -p "$OUTPUT_DIR"
SCRATCH="$(mktemp -d "$OUTPUT_DIR/build-XXXXXX")"
python3 - "$SOURCE_DIR" "$SCRATCH" "$SCRIPT_DIR" <<'PY'
import hashlib,json,pathlib,shutil,sys
source,scratch,driver=map(lambda x:pathlib.Path(x).resolve(),sys.argv[1:])
staged=scratch/'Sources'; staged.mkdir()
for p in source.glob('*.swift'):
    if p.name!='main.swift': shutil.copyfile(p,staged/p.name)
app=(staged/'AppDelegate.swift').read_text()
bridge='''
// Tool-only same-file bridge for this branch's state-based panel.
extension AppDelegate {
    var benchmarkMenuReady: Bool { statusItem != nil && menu != nil }
    var benchmarkHostAlive: Bool { hostingView != nil }
    var benchmarkMenuVisible: Bool { isPanelOpen && (hostingView?.window?.isVisible ?? false) }
    var benchmarkStatusIconPresent: Bool { statusItem?.button?.image != nil }
    var benchmarkWindowNumber: Int? { hostingView?.window?.windowNumber }
    var benchmarkReportCount: Int { BenchmarkAppProbe.reports }
    var benchmarkDataCounts: [String: Int] {
        let history = UsageHistory.shared.snapshot()
        return ["local_cards": currentReport.detectedLLMs.count,
                "remote_devices": currentReport.remoteHosts.count,
                "remote_cards": currentReport.remoteLLMs.values.reduce(0) { $0 + $1.count },
                "remote_successes": currentReport.remoteDeviceStatus.values.filter { $0.lastSuccess != nil }.count,
                "api_providers": currentReport.api.providers.count,
                "history_days": history.days.count, "history_processed_files": history.processedFiles]
    }
    func benchmarkPopUp(at point: NSPoint) { menu.popUp(positioning: nil, at: point, in: nil) }
    func benchmarkCancelMenu() { menu.cancelTracking() }
}
enum BenchmarkAppProbe { static var reports = 0 }
'''
# Tool-only modifications are listed in metadata; production files untouched.
needle='self?.currentReport = report'
assert app.count(needle)==1
app=app.replace(needle,needle+'\n                BenchmarkAppProbe.reports += 1')
for method in ('menuWillOpen', 'menuDidClose', 'menuNeedsUpdate'):
    marker='    func '+method+'(_ menu: NSMenu) {'
    if app.count(marker)!=1: raise SystemExit('Menu audit injection point changed: '+method)
    app=app.replace(marker,marker+'\n        BenchmarkAudit.note("'+method+'", ["was_open": isPanelOpen])')
app=app.replace('self?.menu.cancelTracking()', 'BenchmarkAudit.note("production_cancel_request"); self?.menu.cancelTracking()')

# Safety patch list populated only after coordinator agreement.
patches={
'        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }':'        // Tool: do not alter notification authorization.',
'        autoSyncPricesIfStale()':'        // Tool: do not sync user prices.',
'        DispatchQueue.global(qos: .utility).async { ProxyManager.shared.syncIfInstalled() }':'        // Tool: do not update user proxy. //'}
for old,new in patches.items():
    if app.count(old)!=1: raise SystemExit('Safety injection point changed: '+old)
    app=app.replace(old,new)
(staged/'AppDelegate.swift').write_text(app+bridge)
# Writes go to process-local defaults and copies in the runtime state directory.
# Actual log reads, parsing, scanner queues, SSH and timer cadences remain intact.
cache_patches={
'UsageHistory.swift':('self.cachePath = cachePath ?? "\\(home)/.config/vibedeck/usage-daily.json"','self.cachePath = cachePath ?? BenchmarkState.cachePath(original: "\\(home)/.config/vibedeck/usage-daily.json")'),
'ProcessScanner.swift':('private var samplesPath: String { "\\(home)/.config/vibedeck/quota-samples.json" }','private var samplesPath: String { BenchmarkState.cachePath(original: "\\(home)/.config/vibedeck/quota-samples.json") }')}
for name,(old,new) in cache_patches.items():
    p=staged/name; text=p.read_text()
    if text.count(old)!=1: raise SystemExit('Cache injection point changed: '+name)
    p.write_text(text.replace(old,new))
remote=staged/'RemoteCollector.swift'
text=remote.read_text()
needle='arguments: ["-o", "BatchMode=yes",'
if text.count(needle)!=1: raise SystemExit('SSH safety injection point changed')
remote.write_text(text.replace(needle,'arguments: ["-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "BatchMode=yes",').replace('command: "python3 - "', 'command: "python3 -B - "'))
for p in staged.glob('*.swift'):
    text=p.read_text().replace('UserDefaults.standard.set(', 'BenchmarkState.set(').replace('defaults.set(', 'BenchmarkState.set(')
    p.write_text(text)
shutil.copyfile(driver/'panel-app-benchmark.swift',scratch/'Driver.swift')
resources=source.parent/'Resources'
shutil.copyfile(resources/'Info.plist',scratch/'Info.plist')
meta=dict(target="arm64-apple-macosx14.0",optimization="-O -whole-module-optimization",source_dir=str(source),source_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.glob('*.swift'))},tool_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in driver.glob('panel-app-benchmark.*')},compiled_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(staged.glob('*.swift'))},safety_changes=list(patches)+list(cache_patches)+["all explicit defaults set => BenchmarkState.set", "SSH StrictHostKeyChecking=yes UpdateHostKeys=no; remote Python -B prevents bytecode writes"],rounds=3,phase_seconds=60,safety_seconds=450,early_close_policy="invalid window then continue; cancel stale timers",capture_only_settle_seconds=20,production_main=False)
(scratch/'metadata.json').write_text(json.dumps(meta,indent=2))
PY
mkdir -p "$SCRATCH/tmp" "$SCRATCH/module-cache"
export TMPDIR="$SCRATCH/tmp/"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$SCRATCH/Sources" -name '*.swift' | sort)
FLAGS=(-O -whole-module-optimization -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$SCRATCH/module-cache" -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework UserNotifications -lsqlite3)
if [[ "$MODE" == typecheck ]]; then swiftc "${FLAGS[@]}" -typecheck "${SOURCES[@]}" "$SCRATCH/Driver.swift"; else
BUNDLE="$SCRATCH/VibeDeck.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$SCRATCH/Info.plist" "$BUNDLE/Contents/Info.plist"
# Read-only collector and pricing data are required for unchanged live collection.
# No proxy script or installer assets are bundled.
cp "$(dirname "$SOURCE_DIR")/Resources/prices.builtin.json" "$BUNDLE/Contents/Resources/"
cp "$(dirname "$SOURCE_DIR")/Resources/vibedeck-collector.py" "$BUNDLE/Contents/Resources/"
swiftc "${FLAGS[@]}" "${SOURCES[@]}" "$SCRATCH/Driver.swift" -o "$BUNDLE/Contents/MacOS/VibeDeck"
codesign --force --sign - "$BUNDLE"
python3 - "$SCRATCH" <<'PYMETA'
import hashlib,json,pathlib,sys
scratch=pathlib.Path(sys.argv[1]); p=scratch/'metadata.json'; meta=json.loads(p.read_text())
meta['resources_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (scratch/'VibeDeck.app/Contents/Resources').iterdir()}
meta['read_only_collector_bundled']=True
meta['binary_sha256']=hashlib.sha256((scratch/'VibeDeck.app/Contents/MacOS/VibeDeck').read_bytes()).hexdigest()
p.write_text(json.dumps(meta,indent=2))
PYMETA
echo "READY $BUNDLE"
fi
