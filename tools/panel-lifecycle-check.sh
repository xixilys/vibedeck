#!/bin/bash
# Transient-NSPopover fixture acceptance. No collectors, hardware or persistent preference writes.
# Coordinator must grant a compile slot before `build`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-prepare}"
OUT="${2:-$ROOT/review-shots/lifecycle/candidate}"
case "$MODE" in
prepare)
    mkdir -p "$OUT/Sources" "$OUT/empty-home" "$OUT/results"
    python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys, hashlib, json, re, shutil, os
root, out = map(Path, sys.argv[1:])
source = Path(os.environ.get('VG_LIFECYCLE_SOURCE_DIR', root / 'Sources'))
manifest = {}
for p in sorted(source.glob('*.swift')):
    if p.name == 'main.swift': continue
    text = p.read_text()
    manifest[p.name] = hashlib.sha256(p.read_bytes()).hexdigest()
    # This affects only copies. Defaults remain process-local; home reads use an empty fixture home.
    text = text.replace('UserDefaults.standard', 'LifecycleMemoryDefaults.shared')
    text = re.sub(r'@AppStorage\(("[^"\n]+")\)', r'@AppStorage(\1, store: LifecycleMemoryDefaults.shared)', text)
    text = text.replace('defaults: UserDefaults = .standard', 'defaults: UserDefaults = LifecycleMemoryDefaults.shared')
    text = text.replace('FileManager.default.homeDirectoryForCurrentUser.path', 'LifecycleHooks.fixtureHome')
    (out / 'Sources' / p.name).write_text(text)
for name in ('FanSMC.c', 'FanSMC.h'):
    shutil.copyfile(source / name, out / 'Sources' / name)
def edit(name, before, after):
    p = out / 'Sources' / name
    text = p.read_text()
    n = text.count(before)
    if n != 1: raise RuntimeError(f'{name}: bridge anchor count {n}: {before}')
    p.write_text(text.replace(before, after))
def append(name, text):
    p = out / 'Sources' / name
    p.write_text(p.read_text() + '\n' + text)
# Environment-only bridge: optionally reproduce a smaller available screen without
# changing display settings. All production height arithmetic remains unchanged.
for name, before, count in [
    ('DashboardView.swift', '(NSScreen.main?.visibleFrame.height ?? 900)', 1),
    ('AppDelegate.swift', '(NSScreen.main?.visibleFrame.height ?? 900)', 1),
    ('AppDelegate.swift', '((h.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900)', 1)]:
    p = out / 'Sources' / name
    text = p.read_text()
    if text.count(before) != count: raise RuntimeError(f'{name}: screen bridge anchor changed')
    p.write_text(text.replace(before, 'LifecycleHooks.availableScreenHeight'))
edit('DashboardView.swift', '.onReceive(liveTicker) { date in', '.onAppear { lifecycleRegister() }\n        .onReceive(liveTicker) { date in')
edit('DashboardView.swift', '    @State private var expandedCards: Set<String> = []',
     '    @State private var expandedCards: Set<String> = []\n    @State private var lifecycleUsageExpanded = false\n    @State private var lifecyclePlatformsExpanded = false')
edit('DashboardView.swift', 'DisclosureGroup(L("本机平台详情", "Local platforms")) {',
     'DisclosureGroup(L("本机平台详情", "Local platforms"), isExpanded: $lifecyclePlatformsExpanded) {')
edit('DashboardView.swift', 'DisclosureGroup(L("\\(usage.name) 用量详情", "\\(usage.name) usage details")) {',
     'DisclosureGroup(L("\\(usage.name) 用量详情", "\\(usage.name) usage details"), isExpanded: $lifecycleUsageExpanded) {')
edit('DashboardView.swift', 'content: tabContent.frame(', 'content: LifecycleDisclosureFixture(content: tabContent).frame(')
edit('DashboardView.swift', 'onHeight: { h in', 'onHeight: { h in LifecycleHooks.heights.append(Double(h));')
edit('DashboardView.swift', 'FileManager.default.fileExists(atPath: mount.path)', 'LifecycleHooks.mountProbe(mount.path)')
append('DashboardView.swift', r'''
extension DashboardView {
    func lifecycleRegister() {
        LifecycleHooks.tab = $tab
        LifecycleHooks.detail = $drillDown
        LifecycleHooks.device = $deviceKey
        LifecycleHooks.report = $report
        LifecycleHooks.usageExpanded = $lifecycleUsageExpanded
        LifecycleHooks.platformsExpanded = $lifecyclePlatformsExpanded
        LifecycleHooks.todayCLI = $todayCLIKey
        LifecycleHooks.selectedUsage = { selectedTodayCLI }
        LifecycleHooks.usagePreview = {
            AnyView(todayUsageDetails.padding(12).frame(width: Self.panelWidth)
                .background(Color.white).environment(\.colorScheme, .light))
        }
        LifecycleHooks.refreshMounts = { refreshMountAvailability() }
        LifecycleHooks.mountState = { (mountCheckPending, mountAvailability) }
    }
}
''')
# Preserve the actual popover lifecycle. Do not invoke applicationDidFinishLaunching.
edit('AppDelegate.swift', 'class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {',
     'class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {\n    var lifecycleReads = 0')
edit('AppDelegate.swift', 'guard let button = statusItem.button else { return }',
     'guard let button = statusItem?.button else { return }')
edit('AppDelegate.swift', '    @objc func updateStatus(forceSlow: Bool = true) {',
     '    @objc func updateStatus(forceSlow: Bool = true) {\n        LifecycleHooks.collectorRequests += 1; return // fixture: do not scan processes, credentials or network')
edit('AppDelegate.swift', 'actions.latestReport = { [weak self] in self?.currentReport }',
     'actions.latestReport = { [weak self] in self?.lifecycleReads += 1; return self?.currentReport }')
edit('AppDelegate.swift', 'private func relayoutPanel() {',
     'private func relayoutPanel() {\n        LifecycleHooks.relayoutRequests += 1')
if 'actions.panelHeightChanged =' in (out / 'Sources' / 'AppDelegate.swift').read_text():
    edit('AppDelegate.swift', '        let dashboard = DashboardView(',
         '        LifecycleHooks.heightCallbacks.append(actions.panelHeightChanged)\n        let dashboard = DashboardView(')
# Using the SwiftUI store environment changes only test preference storage, not view logic/types.
edit('DashboardView.swift', '.background(MenuMaterial())',
     '.background(MenuMaterial())\n        .defaultAppStorage(LifecycleMemoryDefaults.shared)')
append('AppDelegate.swift', r'''
extension AppDelegate {
    func lifecyclePrepare(_ report: ScanReport) {
        currentReport = report
        setupStatusItem()
        statusItem.button?.title = "VG fixture"
    }
    func lifecycleOpen() -> NSView {
        showPanel()
        return hostingView!
    }
    func lifecycleClose() { closePanel() }
    func lifecyclePublish(_ report: ScanReport) { currentReport = report }
    func lifecycleRequestLayout() { relayoutPanel() }
    var lifecycleHost: NSView? { hostingView }
    var lifecycleContentPresent: Bool { panelPopover.contentViewController != nil }
    var lifecyclePopoverShown: Bool { panelPopover.isShown }
    var lifecycleMonitorCount: Int { (scrollMonitor == nil ? 0 : 1) + (panelKeyMonitor == nil ? 0 : 1) }
    var lifecyclePopover: NSPopover { panelPopover }
    var lifecycleVisible: Bool { isPanelOpen }
    var lifecyclePendingHeight: CGFloat? { pendingPanelHeight }
}
''')
# Passive geometry markers on the real header/footer, only in the copied fixture.
p = out / 'Sources' / 'DashboardView.swift'
t = p.read_text()
t = t.replace('            headerBar\n', '            headerBar.background(LifecycleInputTarget(id: "geometry.header"))\n', 1)
t = t.replace('            footerBar\n', '            footerBar.background(LifecycleInputTarget(id: "geometry.footer"))\n', 1)
p.write_text(t)
# The UI uses demo data, and explicit readSnapshot tests replace only the hardware
# operation with a bounded blocking fixture. The production queue and in-flight gate remain intact.
edit('DashboardView.swift', 'FanControlCard()', 'FanControlCard(demo: true)')
edit('FanControl.swift', '    func snapshot() -> Result<[FanReading], FanControlError> {',
     '    func snapshot() -> Result<[FanReading], FanControlError> {\n        return LifecycleHooks.fanSnapshot() // fixture: never reach AppleSMC')
for token in ['"settings.open"', '"settings.font.\\(preset.value)"', '"settings.language.\\(language.rawValue)"']:
    anchor = '.accessibilityIdentifier(' + token + ')'
    edit('DashboardView.swift', anchor, anchor + '\n                    .background(LifecycleInputTarget(id: ' + token + '))')
edit('DesignSystem.swift', '        .accessibilityLabel(title)\n        .popover(isPresented: $presented, arrowEdge: .bottom) {',
     '        .accessibilityLabel(title)\n        .background(LifecycleInputTarget(id: "info." + title))\n        .popover(isPresented: $presented, arrowEdge: .bottom) {')
edit('StatsTabView.swift', 'Label(L("历史与构成", "History & breakdown"), systemImage: "chart.bar.xaxis")\n                    .font(VG.body)',
     'Label(L("历史与构成", "History & breakdown"), systemImage: "chart.bar.xaxis")\n                    .font(VG.body)\n                    .background(LifecycleInputTarget(id: "stats.history"))')
append('UsageHistory.swift', '''extension UsageHistory {
    func lifecycleSet(_ value: Snapshot) { lock.lock(); cached = value; lock.unlock() }
}''')
append('NetworkScanner.swift', '''extension NetworkScanner {
    func lifecycleSet(_ value: NetworkSnapshot) { lock.lock(); snapshotCache = value; lock.unlock() }
}''')
append('HealthViews.swift', r'''
extension UnifiedQuotaSection {
    func lifecycleReadings() -> [[String: Any]] {
        devices.map { d in ["host": d.host ?? "local", "percentages": d.rings.map { $0.window.usedPct },
            "trusted": d.rings.map { isTrusted($0, device: d) }] }
    }
}
''')
(out / 'Sources' / 'main.swift').write_text((root / 'tools/panel-lifecycle-check.swift').read_text())
(out / 'Sources' / 'NativePopupCheck.swift').write_text((root / 'tools/native-popups.swift').read_text())
(out / 'Sources' / 'PanelInputCheck.swift').write_text((root / 'tools/panel-input-check.swift').read_text())
(out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True))
print('Prepared copied production sources and explicit tool-only bridges at', out)
PY
    ;;
build)
    test -f "$OUT/source-manifest.json"
    mkdir -p "$OUT/LifecycleCheck.app/Contents/MacOS" "$OUT/LifecycleCheck.app/Contents/Resources"
    cat > "$OUT/LifecycleCheck.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>invalid.example.vibedeck-lifecycle</string><key>CFBundleExecutable</key><string>LifecycleCheck</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
    cp "$ROOT/Resources/prices.builtin.json" "$OUT/LifecycleCheck.app/Contents/Resources/"
    clang -O2 -target arm64-apple-macosx14.0 -c "$OUT/Sources/FanSMC.c" -o "$OUT/FanSMC.o"
    swiftc -Onone -target arm64-apple-macosx14.0 -framework Cocoa -framework SwiftUI \
        -framework ServiceManagement -framework UserNotifications -framework IOKit -framework Security -lsqlite3 \
        -import-objc-header "$OUT/Sources/FanSMC.h" \
        "$OUT"/Sources/*.swift "$OUT/FanSMC.o" -o "$OUT/LifecycleCheck.app/Contents/MacOS/LifecycleCheck" > "$OUT/build.log" 2>&1
    ;;
run|input)
    LANG_NAME="${3:-en}"
    SCALE="${4:-1.3}"
    SCREEN_HEIGHT="${5:-}"
    TEST_HOME="$(cd "$OUT/empty-home" && pwd)"
    INPUT_MODE=""
    if [[ "$MODE" == input ]]; then INPUT_MODE=1; fi
    CFFIXED_USER_HOME="$TEST_HOME" VG_LIFECYCLE_INPUT_ONLY="$INPUT_MODE" VG_LIFECYCLE_SCREEN_HEIGHT="$SCREEN_HEIGHT" "$OUT/LifecycleCheck.app/Contents/MacOS/LifecycleCheck" "$OUT/results" "$TEST_HOME" "$SCALE" -AppleLanguages "($LANG_NAME)"
    ;;
*) echo 'Usage: panel-lifecycle-check.sh prepare|build|run|input OUTPUT [en|zh-Hans] [0.85|1.3] [available-screen-height]' >&2; exit 2;;
esac
