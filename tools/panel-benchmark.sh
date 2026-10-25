#!/bin/bash
# Same driver for c46e6d3 state-based Dashboard and its candidate. No collectors.
# Usage: panel-benchmark.sh [--build-only|--typecheck] output.json seconds tab source-dir binary
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE=run
case "${1:-}" in --build-only) MODE=build; shift;; --typecheck) MODE=typecheck; shift;; esac
OUT="${1:?output json}"; SECONDS_PER_PHASE="${2:-30}"; TAB="${3:-0}"; SOURCE_DIR="${4:?source dir}"
SCRATCH="${OUT%.json}.build"; BIN="${5:-$SCRATCH/panel-benchmark}"
mkdir -p "$SCRATCH/tmp" "$SCRATCH/module-cache" "$(dirname "$BIN")"
export TMPDIR="$SCRATCH/tmp/"
python3 - "$SOURCE_DIR" "$SCRATCH" "$SCRIPT_DIR" <<'PY'
import hashlib,json,pathlib,re,sys
source,scratch,driver=map(lambda s:pathlib.Path(s).resolve(),sys.argv[1:])
dash=(source/'DashboardView.swift').read_text(); app=(source/'AppDelegate.swift').read_text()
marker='        .onAppear { refreshLive() }'
if dash.count(marker)!=1: raise SystemExit('Dashboard injection point changed')
# Receipt observes actual Dashboard @State revision after its visible tree update.
bridge='''        .onReceive(NotificationCenter.default.publisher(for: .init("VGBenchmarkReport"))) { note in
            if let value = note.object as? ScanReport { report = value }
        }
        .background(ReportReceiptView(revision: report.tokens.todayTurns, receipt: BenchmarkProbe.receipt!).frame(width: 0, height: 0))
'''
init='''
extension DashboardView {
    init(benchmarkReport: ScanReport, history: UsageHistory.Snapshot, network: NetworkSnapshot, benchmarkActions: PanelActions) {
        self.init(report: benchmarkReport, settings: PanelSettings(), actions: benchmarkActions, preload: false)
        _history = State(initialValue: history)
        _network = State(initialValue: network)
    }
}
'''
(scratch/'DashboardView.swift').write_text(dash.replace(marker,bridge+marker)+init)
ticker=re.search(r'Timer.publish\(every:\s*([\d.]+)',dash)
close=re.search(r'func menuDidClose\([^\n]*\{(.*?)\n    }',app,re.S)
if not close: raise SystemExit('Unknown close policy')
release='menu.removeAllItems()' in close[1] and 'hostingView = nil' in close[1]
meta=dict(schema=3,fixture_epoch=1792147200,optimization="-O -whole-module-optimization",source_dir=str(source),source_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.glob('*.swift'))},driver_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in driver.glob('panel-benchmark.*')},ticker_seconds=float(ticker[1]),releases_hidden_host=release,fixture='four-device local/remote/zero/full/stale; token/API/disk rows; empty history and network',report_cadence_seconds=8)
(scratch/'metadata.json').write_text(json.dumps(meta,indent=2))
(scratch/'Config.swift').write_text('enum BenchmarkConfig {\nstatic let releasesHiddenHost = '+str(release).lower()+'\nstatic let visibleOnly = true\nstatic let metadataJSON = #"'+json.dumps(meta)+'"#\n}\n')
PY
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$SOURCE_DIR" -maxdepth 1 -name '*.swift' ! -name main.swift ! -name AppDelegate.swift ! -name DashboardView.swift | sort)
FLAGS=(-O -whole-module-optimization -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$SCRATCH/module-cache" -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework UserNotifications -lsqlite3)
# AppDelegate types are required; no delegate is instantiated and no launch occurs.
INPUTS=("${SOURCES[@]}" "$SOURCE_DIR/AppDelegate.swift" "$SCRATCH/DashboardView.swift" "$SCRATCH/Config.swift" "$SCRIPT_DIR/panel-benchmark.swift")
if [[ "$MODE" == typecheck ]]; then swiftc "${FLAGS[@]}" -typecheck "${INPUTS[@]}"; else
swiftc "${FLAGS[@]}" "${INPUTS[@]}" -o "$BIN"
echo "READY $BIN"
if [[ "$MODE" == run ]]; then "$BIN" "$OUT" "$SECONDS_PER_PHASE" "$TAB"; fi
fi
