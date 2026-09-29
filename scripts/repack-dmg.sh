#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity="Developer ID Application: ryuya watanabe (FZ35ZF3CZV)"
app="Build/DerivedData/Build/Products/Release/MochiLog Mac.app"
codesign --verify --deep --strict "$app"
rm -rf Build/Stage
mkdir -p Build/Stage
ditto "$app" "Build/Stage/MochiLog Mac.app"
ln -sfn /Applications Build/Stage/Applications
for attempt in 1 2 3; do
  if hdiutil create -volname 'MochiLog Mac Beta' -srcfolder Build/Stage \
    -ov -format UDZO Build/MochiLog-Mac-Beta.dmg; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo 'DMG creation failed after three attempts' >&2
    exit 1
  fi
  echo "DMG creation was busy; retrying ($attempt/3)" >&2
  sleep 5
done
codesign --force --timestamp --sign "$identity" Build/MochiLog-Mac-Beta.dmg
codesign --verify --verbose=2 Build/MochiLog-Mac-Beta.dmg
