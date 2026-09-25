#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
identity="Developer ID Application: ryuya watanabe (FZ35ZF3CZV)"
python_bin="${MOCHILOG_PYTHON_BIN:-python3}"
mkdir -p Build
"$python_bin" -m venv Build/venv
Build/venv/bin/python -m pip install --disable-pip-version-check -r requirements-build.txt
Build/venv/bin/pyinstaller --onefile --noconfirm --clean \
  --name pymobiledevice3 --collect-all pymobiledevice3 \
  --codesign-identity "$identity" --osx-entitlements-file MacCompanion.entitlements \
  --distpath Build/Collector --workpath Build/PyInstaller CollectorEntry.py
xcodegen generate --spec project.yml
xcodebuild -project MochiLogMac.xcodeproj -scheme MochiLogMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO build

app="Build/DerivedData/Build/Products/Release/MochiLog Mac.app"
mkdir -p "$app/Contents/Resources/Collector" Build/Stage
cp Build/Collector/pymobiledevice3 "$app/Contents/Resources/Collector/pymobiledevice3"
cp LICENSE "$app/Contents/Resources/LICENSE-MochiLog.txt"
license_file="$(find Build/venv/lib -path '*/pymobiledevice3-*.dist-info/licenses/LICENSE' -type f -print -quit)"
test -n "$license_file"
cp "$license_file" "$app/Contents/Resources/LICENSE-pymobiledevice3.txt"
cp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"

codesign --force --options runtime --timestamp --sign "$identity" \
  --entitlements MacCompanion.entitlements "$app/Contents/Resources/Collector/pymobiledevice3"
codesign --force --deep --options runtime --timestamp --sign "$identity" \
  --entitlements MacCompanion.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

rm -rf Build/Stage
mkdir -p Build/Stage
ditto "$app" "Build/Stage/MochiLog Mac.app"
ln -sfn /Applications Build/Stage/Applications
hdiutil create -volname 'MochiLog Mac Beta' -srcfolder Build/Stage \
  -ov -format UDZO Build/MochiLog-Mac-Beta.dmg
codesign --force --timestamp --sign "$identity" Build/MochiLog-Mac-Beta.dmg
codesign --verify --verbose=2 Build/MochiLog-Mac-Beta.dmg
shasum -a 256 Build/MochiLog-Mac-Beta.dmg
