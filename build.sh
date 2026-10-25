#!/bin/bash
# 构建两个独立 App，可单独安装/运行：
#   1) Claude IP 桌宠.app   —— 仅悬浮桌宠 + 检测面板
#   2) Claude IP 组件.app   —— 仅桌面小组件宿主（静默、无窗口）
set -euo pipefail
cd "$(dirname "$0")"

PET="dist/Claude IP 桌宠.app"
HOST="dist/Claude IP 组件.app"
PET_BIN="ClaudeIPPet"
HOST_BIN="ClaudeIPWidgetHost"
WAPP="$HOST/Contents/PlugIns/ClaudeIPWidget.appex"

pluginkit -r "$PET/Contents/PlugIns/ClaudeIPWidget.appex" 2>/dev/null || true
rm -rf "$PET" "$HOST"
mkdir -p "$PET/Contents/MacOS" "$PET/Contents/Resources/web"
mkdir -p "$HOST/Contents/MacOS" "$WAPP/Contents/MacOS"

echo "==> compiling pet app (independent)"
swiftc -O -target arm64-apple-macos13.0 src/main.swift \
  -o "$PET/Contents/MacOS/$PET_BIN" \
  -framework Cocoa -framework WebKit
cp src/web/index.html src/web/pet.css src/web/pet.js src/web/jarvis.css src/web/jarvis.js src/web/hud-world.js "$PET/Contents/Resources/web/"
cp -X widget/Resources/HUDBackground.png "$PET/Contents/Resources/web/hud-frame.png"

echo "==> compiling WidgetKit extension"
swiftc -parse-as-library -O -target arm64-apple-macos14.0 \
  widget/SharedData.swift widget/WebRTCUDP.swift widget/WebRTCUDPProbe.swift widget/RefreshPresentation.swift widget/WidgetRipple.swift widget/WidgetViews.swift widget/HUDLargeView.swift widget/LiquidGlassView.swift widget/WidgetMain.swift \
  -o "$WAPP/Contents/MacOS/ClaudeIPWidget" \
  -framework SwiftUI -framework WidgetKit -framework WebKit \
  -Xlinker -e -Xlinker _NSExtensionMain
cp widget/Info.plist "$WAPP/Contents/Info.plist"
mkdir -p "$WAPP/Contents/Resources"
cp -X widget/Resources/HUDBackground.png widget/Resources/HUDWorld.json "$WAPP/Contents/Resources/"

echo "==> compiling widget host (silent)"
swiftc -O -target arm64-apple-macos14.0 src/host/main.swift widget/SharedData.swift widget/WebRTCUDP.swift widget/WebRTCUDPProbe.swift widget/RefreshPresentation.swift \
  -o "$HOST/Contents/MacOS/$HOST_BIN" \
  -framework Cocoa -framework WidgetKit -framework WebKit

echo "==> writing Info.plist"
cat > "$PET/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude IP 桌宠</string>
  <key>CFBundleDisplayName</key><string>Claude IP 桌宠</string>
  <key>CFBundleIdentifier</key><string>coffee.net.claude-ip-pet</string>
  <key>CFBundleExecutable</key><string>ClaudeIPPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial desktop pet for ip.net.coffee/claude</string>
</dict>
</plist>
PLIST

cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude IP 组件</string>
  <key>CFBundleDisplayName</key><string>Claude IP 组件</string>
  <key>CFBundleIdentifier</key><string>coffee.net.claude-ip-pet.widgethost</string>
  <key>CFBundleExecutable</key><string>ClaudeIPWidgetHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial widget host for ip.net.coffee/claude</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>coffee.net.claude-ip-pet.widget.action</string>
      <key>CFBundleURLSchemes</key><array><string>claudeipwidget</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --sign - --entitlements widget/widget.entitlements "$WAPP"
codesign --force --sign - "$HOST"
codesign --force --sign - "$PET"

echo "==> registering"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$HOST" >/dev/null 2>&1 || true
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PET" >/dev/null 2>&1 || true
pluginkit -a "$WAPP" 2>/dev/null || true
pluginkit -e use -i coffee.net.claude-ip-pet.widget 2>/dev/null || true

echo "build ok:"
echo "  $(pwd)/$PET   (桌宠，可单独使用)"
echo "  $(pwd)/$HOST   (组件宿主，可单独使用)"
