#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Bundle/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Bundle/Info.plist)
APP="$PWD/Build/StellarScope.app"
DIST="$PWD/Dist"
STAGE="$PWD/Build/ReleaseStage"
ZIP="$DIST/StellarScope-$VERSION.app.zip"
DMG="$DIST/StellarScope-$VERSION.dmg"
VOLNAME="StellarScope $VERSION"

echo "== Build StellarScope $VERSION ($BUILD) =="
STELLARSCOPE_SKIP_OPEN=1 "$PWD/scripts/build_and_run.command"

rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST" "$STAGE"
cp -R "$APP" "$STAGE/StellarScope.app"
ln -s /Applications "$STAGE/Applications"

echo "== Create ZIP =="
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== Create DMG =="
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

shasum -a 256 "$ZIP" "$DMG" > "$DIST/SHA256SUMS.txt"

echo "== Release artifacts =="
ls -lh "$ZIP" "$DMG" "$DIST/SHA256SUMS.txt"
