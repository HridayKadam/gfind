#!/bin/zsh
# Builds dist/GFind.app and dist/GFind.dmg.
#   ./build.sh           build only
#   ./build.sh install   build, install to /Applications and launch
#
# Signing (optional, for distributing to other Macs):
#   GFIND_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign with your Developer ID
#   GFIND_NOTARY_PROFILE="gfind-notary"                                   also notarise and staple
#     (create the profile once with: xcrun notarytool store-credentials gfind-notary)
# Without these the app is ad-hoc signed, which is fine on the Mac that built it.
set -euo pipefail
cd "$(dirname "$0")"

# Universal (Apple silicon + Intel) builds need full Xcode, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${GFIND_SIGN_IDENTITY:--}"
DIST="dist"
APP="$DIST/GFind.app"

swift build -c release --arch arm64 --arch x86_64
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/GFind" "$APP/Contents/MacOS/GFind"

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
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Hriday Kadam</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>GFind shows and searches the files on your Desktop. Nothing is uploaded.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>GFind shows and searches your Documents. Nothing is uploaded.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>GFind shows your downloads and where they came from. Nothing is uploaded.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>The notch shows your next seven days of events.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>The notch shows your reminders and lets you tick them off.</string>
</dict>
</plist>
PLIST

if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --entitlements GFind.entitlements --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "GFind" -srcfolder "$STAGE" -ov -format UDZO "$DIST/GFind.dmg" >/dev/null
if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DIST/GFind.dmg"
    if [[ -n "${GFIND_NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DIST/GFind.dmg" --keychain-profile "$GFIND_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DIST/GFind.dmg"
        xcrun stapler staple "$APP"
        spctl --assess --type open --context context:primary-signature -v "$DIST/GFind.dmg"
    fi
fi
echo "Built $PWD/$APP (version $VERSION, build $BUILD, signed: ${IDENTITY/#-/ad-hoc})"
echo "Built $PWD/$DIST/GFind.dmg"

if [[ "${1:-}" == "install" ]]; then
    pkill -x GFind 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/GFind.app
    cp -R "$APP" /Applications/
    open /Applications/GFind.app
    echo "Installed and launched /Applications/GFind.app"
fi
