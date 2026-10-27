#!/bin/bash
set -e

APP_NAME="VibeDeck"
OUTPUT_DIR="${OUTPUT_DIR:-build-obs}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 正在编译 ${APP_NAME}..."
cd "${BUILD_DIR}"

rm -rf "${APP_BUNDLE}"
rm -f "${OUTPUT_DIR}/${APP_NAME}" "${OUTPUT_DIR}/${APP_NAME}"-* "${OUTPUT_DIR}/VibeDeckFanHelper" "${OUTPUT_DIR}/VibeDeckFanHelper"-*

# 默认 Universal（Apple Silicon + Intel）；本地调试可 ARCHS=arm64 ./build.sh 只编一份
ARCHS="${ARCHS:-arm64 x86_64}"
for ARCH in ${ARCHS}; do
    echo "    - ${ARCH}"
    clang -O2 -target "${ARCH}-apple-macosx14.0" -c Sources/FanSMC.c -o "${OUTPUT_DIR}/FanSMC-${ARCH}.o"
    swiftc -O \
        -target "${ARCH}-apple-macosx14.0" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework ServiceManagement \
        -framework UserNotifications \
        -framework IOKit \
        -framework Security \
        -import-objc-header Sources/FanSMC.h \
        -lsqlite3 \
        Sources/UITheme.swift \
        Sources/DesignSystem.swift \
        Sources/GlassKit.swift \
        Sources/SystemMonitor.swift \
        Sources/SystemTabView.swift \
        Sources/OverviewViews.swift \
        Sources/PricingCatalog.swift \
        Sources/AccountIdentity.swift \
        Sources/AccountPresence.swift \
        Sources/AccountUsage.swift \
        Sources/AccountMonitor.swift \
        Sources/MoneyDisplay.swift \
        Sources/AccountViews.swift \
        Sources/PriceSync.swift \
        Sources/CodexProcessMonitor.swift \
        Sources/CodexProcessViews.swift \
        Sources/ProcessScanner.swift \
        Sources/ProxyManager.swift \
        Sources/NetworkScanner.swift \
        Sources/NetworkTabView.swift \
        Sources/OpenCodeUsage.swift \
        Sources/RemoteCollector.swift \
        Sources/UsageHistory.swift \
        Sources/Observability.swift \
        Sources/UsageForecast.swift \
        Sources/NerfDetector.swift \
        Sources/StatsTabView.swift \
        Sources/HealthViews.swift \
        Sources/FanControl.swift \
        Sources/FanThermostat.swift \
        Sources/FanThermostatSelfTest.swift \
        Sources/FanHardware.swift \
        Sources/FanService.swift \
        Sources/FanServiceProtocol.swift \
        Sources/FanServiceSelfTest.swift \
        Sources/PricingViews.swift \
        Sources/DashboardView.swift \
        Sources/DevicePicker.swift Sources/MenuBarPet.swift \
        Sources/AppDelegate.swift \
        Sources/main.swift \
        "${OUTPUT_DIR}/FanSMC-${ARCH}.o" \
        -o "${OUTPUT_DIR}/${APP_NAME}-${ARCH}"
    swiftc -O \
        -target "${ARCH}-apple-macosx14.0" \
        -framework Foundation -framework IOKit -framework Security \
        -import-objc-header Sources/FanSMC.h \
        Sources/FanServiceProtocol.swift Sources/FanHardware.swift \
        FanHelper/SelfTest.swift FanHelper/main.swift \
        "${OUTPUT_DIR}/FanSMC-${ARCH}.o" \
        -o "${OUTPUT_DIR}/VibeDeckFanHelper-${ARCH}"
done
lipo -create "${OUTPUT_DIR}/${APP_NAME}"-* -output "${OUTPUT_DIR}/${APP_NAME}"
lipo -create "${OUTPUT_DIR}/VibeDeckFanHelper"-* -output "${OUTPUT_DIR}/VibeDeckFanHelper"
rm -f "${OUTPUT_DIR}/${APP_NAME}"-* "${OUTPUT_DIR}/VibeDeckFanHelper"-* "${OUTPUT_DIR}"/FanSMC-*.o

echo "==> 正在构建 App Bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchServices"

mv "${OUTPUT_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
mv "${OUTPUT_DIR}/VibeDeckFanHelper" "${APP_BUNDLE}/Contents/Library/LaunchServices/VibeDeckFanHelper"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp Resources/vibedeck-proxy.py "${APP_BUNDLE}/Contents/Resources/vibedeck-proxy.py"
cp Resources/vibedeck-collector.py "${APP_BUNDLE}/Contents/Resources/vibedeck-collector.py"
cp Resources/prices.builtin.json "${APP_BUNDLE}/Contents/Resources/prices.builtin.json"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "==> 正在签名..."
codesign --force --sign - "${APP_BUNDLE}/Contents/Library/LaunchServices/VibeDeckFanHelper"
codesign --force --sign - "${APP_BUNDLE}"

echo "==> 编译构建完成: ${APP_BUNDLE}"
