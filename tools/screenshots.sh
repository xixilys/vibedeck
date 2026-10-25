#!/bin/bash
# Review-only native hosts. No AppDelegate, collectors, credentials or production preference writes.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_DIR="${1:-Sources}"
OUTPUT="${2:-review-shots/final}"
SCRATCH="${3:-/tmp/vibedeck-v2-screenshots}"
mkdir -p "$SCRATCH/Sources" "$OUTPUT"
cp "$SOURCE_DIR"/*.swift "$SCRATCH/Sources/"
cp "$SOURCE_DIR"/FanSMC.c "$SOURCE_DIR"/FanSMC.h "$SCRATCH/Sources/"
python3 - "$SCRATCH/Sources/DashboardView.swift" <<'PYCODE'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
if 'public var panelHeightChanged:' not in text:
    text=text.replace('public struct PanelActions {', 'public struct PanelActions {\n    public var panelHeightChanged: (CGFloat) -> Void = { _ in }')
# Fixture-native body remains static; no real collector cache may replace the injected state.
text=text.replace('private func refreshLive() {', 'private func refreshLive() {\n        guard actions.isVisible() else { return }')
p.write_text(text)
prices = p.parent / 'PricingViews.swift'
text = prices.read_text().replace('let path = PriceSync.pricesPath(home: FileManager.default.homeDirectoryForCurrentUser.path)', 'let path = ProcessInfo.processInfo.environment["VG_REVIEW_PRICES"] ?? "/nonexistent/vibedeck-review-prices.json"')
prices.write_text(text)
PYCODE
cat >> "$SCRATCH/Sources/DashboardView.swift" <<'SWIFT'

// Tool-only private-state injection. This extension never enters the delivery app.
extension DashboardView {
    static func review(report: ScanReport, history: UsageHistory.Snapshot, network: NetworkSnapshot, drill: String? = nil) -> DashboardView {
        var actions = PanelActions()
        actions.isVisible = { false }
        var view = DashboardView(report: report, settings: PanelSettings(fontScale: Double(UITheme.fontScale)), actions: actions, preload: false, drill: drill)
        view._drillDown = State(initialValue: drill)
        view._history = State(initialValue: history)
        view._network = State(initialValue: network)
        view._liveNow = State(initialValue: Date(timeIntervalSince1970: ReviewFixtures.now))
        return view
    }
    var reviewSettingsSection: some View { settingsSection.padding(12).frame(width: Self.panelWidth) }
    var reviewDeviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("设备额度 · 本机与 WSL / SSH", "Device quotas · Local and WSL / SSH")).font(VG.headline)
            UnifiedQuotaSection(report: report, scope: .all, now: nowTS, openLocal: { _ in }, openDevice: { _ in })
        }.padding(12).frame(width: Self.panelWidth)
    }
}
SWIFT
cp tools/screenshots.swift "$SCRATCH/Screenshots.swift"
SOURCES=()
for FILE in "$SCRATCH"/Sources/*.swift; do
    [[ "$FILE" == */main.swift ]] || SOURCES+=("$FILE")
done
BUNDLE="$SCRATCH/PanelReview.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$(dirname "$SOURCE_DIR")/Resources/prices.builtin.json" "$BUNDLE/Contents/Resources/"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vibedeck.PanelReviewV2</string>
<key>CFBundleName</key><string>VibeDeck Review</string>
<key>CFBundleExecutable</key><string>PanelReview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
clang -O2 -target "$(uname -m)-apple-macosx14.0" -c "$SCRATCH/Sources/FanSMC.c" -o "$SCRATCH/FanSMC.o"
swiftc -O -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework UserNotifications -framework IOKit -framework Security -lsqlite3 \
    -import-objc-header "$SCRATCH/Sources/FanSMC.h" \
    "${SOURCES[@]}" "$SCRATCH/Screenshots.swift" "$SCRATCH/FanSMC.o" -o "$BUNDLE/Contents/MacOS/PanelReview"
for LANGUAGE in zh-Hans en; do
    "$BUNDLE/Contents/MacOS/PanelReview" --output "$OUTPUT" --language "$LANGUAGE" -AppleLanguages "($LANGUAGE)"
done
