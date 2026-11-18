#!/bin/bash
# Сборка Tutun.app в build/. Использование: scripts/build.sh [--install]  (--install кладёт в /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Tutun.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Tutun" "$APP/Contents/MacOS/Tutun"
cp "$BIN/tutund" "$BIN/tutun-drop" vendor/bin/xray vendor/bin/sing-box \
   scripts/install.sh scripts/uninstall.sh scripts/update-swap.sh assets/AppIcon.icns "$APP/Contents/Resources/"
# Гео-базы — с исходной датой (-p): install.sh ставит их, только если они новее баз, которые служба уже обновила.
# Без -p у копии была дата сборки, и каждое «Обновить службу» откатывало скачанные базы к вшитым.
cp -p vendor/bin/geoip.dat vendor/bin/geosite.dat "$APP/Contents/Resources/"
VERSION=$(date +%Y.%m.%d.%H%M)
APP_VERSION=$(tr -d '[:space:]' < VERSION)   # номер выпуска; по нему приложение сравнивает себя с GitHub
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tutun</string>
  <key>CFBundleDisplayName</key><string>Tutun</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleIdentifier</key><string>local.tutun.app</string>
  <key>CFBundleExecutable</key><string>Tutun</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Подписки по http:// (только при включённом «Разрешить подписки по http»): без этого macOS блокирует http-запросы. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Tutun</string>
      <key>CFBundleURLSchemes</key>
      <array><string>tutun</string><string>vless</string><string>vmess</string><string>trojan</string><string>ss</string>
             <string>hysteria2</string><string>hy2</string><string>tuic</string><string>wireguard</string><string>socks</string></array>
    </dict>
  </array>
</dict>
</plist>
PL

mkdir -p "$APP/Contents/Resources/Licenses"
cp licenses/* "$APP/Contents/Resources/Licenses/"
SIGN_IDENTITY="${TUTUN_MAC_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force)
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_OPTIONS=(--force --options runtime --timestamp); fi
for f in tutund tutun-drop xray sing-box; do codesign "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" "$APP/Contents/Resources/$f"; done
codesign "${SIGN_OPTIONS[@]}" -s "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Собрано: $APP"
if [ "${1:-}" = "--install" ]; then
  pkill -x Tutun 2>/dev/null || true
  rm -rf /Applications/Tutun.app
  /usr/bin/ditto "$APP" /Applications/Tutun.app   # ditto сохраняет даты файлов (важно для гео-баз)
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tutun.app
  echo "Установлено в /Applications/Tutun.app"
fi
