#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='Build/DerivedData/Build/Products/Release/MochiLog Mac.app'
key="${MOCHILOG_SPARKLE_KEY_PATH:?Set the private signing key path outside the repository}"
test -f "$key"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ "$version" == 0.* ]]
notes="docs/RELEASE_NOTES_$version.md"
test -f "$notes"
bin='Build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin'
mkdir -p Build/UpdateFeed
cp Build/MochiLog-Mac-Beta.dmg Build/UpdateFeed/
cp "$notes" Build/UpdateFeed/MochiLog-Mac-Beta.md
"$bin/generate_appcast" --maximum-deltas 0 --embed-release-notes --ed-key-file "$key" \
  --download-url-prefix "https://github.com/MochiLog/MochiLog-Mac/releases/download/v$version/" \
  -o Build/UpdateFeed/appcast.xml Build/UpdateFeed
"$bin/sign_update" --ed-key-file "$key" Build/UpdateFeed/appcast.xml
"$bin/sign_update" --verify --ed-key-file "$key" Build/UpdateFeed/appcast.xml
grep -q 'sparkle:edSignature=' Build/UpdateFeed/appcast.xml
grep -q "<sparkle:version>$build</sparkle:version>" Build/UpdateFeed/appcast.xml
