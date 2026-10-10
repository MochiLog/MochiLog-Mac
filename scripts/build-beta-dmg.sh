#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
identity="Developer ID Application: ryuya watanabe (FZ35ZF3CZV)"
export MOCHILOG_COLLECTOR_SIGN_IDENTITY="$identity"
bash scripts/build-collector.sh
Build/Collector/pymobiledevice3 --help > Build/collector-smoke.txt
xcodegen generate --spec project.yml
app="Build/DerivedData/Build/Products/Release/MochiLog Mac.app"
# A previously notarized app cannot be modified in place on macOS. Keep it in
# the staging directory until the new build has completed.
if [[ -d "$app" ]]; then
  mkdir -p Build/Stage
  mv "$app" "Build/Stage/previous-$(date +%s).app"
fi
xcodebuild -project MochiLogMac.xcodeproj -scheme MochiLogMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO -jobs "${MOCHILOG_COMPILER_JOBS:-1}" build

mkdir -p "$app/Contents/Resources/Collector" Build/Stage
rm -rf "$app/Contents/Resources/Collector"
ditto Build/Collector "$app/Contents/Resources/Collector"
cp LICENSE "$app/Contents/Resources/LICENSE-MochiLog.txt"
cp Resources/RuntimeLicenses/Python-3.13-LICENSE.txt \
  "$app/Contents/Resources/LICENSE-Python-Runtime.txt"
license_file="$(find Build/NuitkaVenv/lib -path '*/pymobiledevice3-*.dist-info/licenses/LICENSE' -type f -print -quit)"
test -n "$license_file"
cp "$license_file" "$app/Contents/Resources/LICENSE-pymobiledevice3.txt"
cp Build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/LICENSE \
  "$app/Contents/Resources/LICENSE-Sparkle.txt"
Build/NuitkaVenv/bin/python scripts/bundle-python-licenses.py \
  "$app/Contents/Resources/LICENSE-Python-Dependencies.txt"
cp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"

codesign --force --options runtime --timestamp --sign "$identity" \
  --entitlements MacCompanion.entitlements "$app/Contents/Resources/Collector/pymobiledevice3"
codesign --force --deep --options runtime --timestamp --sign "$identity" \
  --entitlements MacCompanion.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

bash scripts/repack-dmg.sh
shasum -a 256 Build/MochiLog-Mac-Beta.dmg
