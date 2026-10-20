#!/bin/zsh
# Builds dist/GFind.app and dist/GFind.dmg.
#   ./build.sh           build only
#   ./build.sh install   build, install to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
DIST="dist"
APP="$DIST/GFind.app"

swift build -c release
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/GFind" "$APP/Contents/MacOS/GFind"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.hriday.gfind</string>
    <key>CFBundleName</key><string>GFind</string>
    <key>CFBundleDisplayName</key><string>GFind</string>
    <key>CFBundleExecutable</key><string>GFind</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Hriday Kadam</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>GFind shows and searches the files on your Desktop. Nothing is uploaded.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>GFind shows and searches your Documents. Nothing is uploaded.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>GFind shows your downloads and where they came from. Nothing is uploaded.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "GFind" -srcfolder "$STAGE" -ov -format UDZO "$DIST/GFind.dmg" >/dev/null
echo "Built $PWD/$APP"
echo "Built $PWD/$DIST/GFind.dmg"

if [[ "${1:-}" == "install" ]]; then
    pkill -x GFind 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/GFind.app
    cp -R "$APP" /Applications/
    open /Applications/GFind.app
    echo "Installed and launched /Applications/GFind.app"
fi
