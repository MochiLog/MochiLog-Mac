#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
app="Build/DerivedData/Build/Products/Release/MochiLog Mac.app"
dmg="Build/MochiLog-Mac-Beta.dmg"
key="${MOCHILOG_SPARKLE_KEY_PATH:-}"
test -n "$key" && test -f "$key"
test -f "$dmg"
test -d "$app"
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
codesign --verify --deep --strict "$app"
test -z "$(git status --porcelain)" || {
  echo 'Commit and push the source before publishing a release.' >&2
  exit 1
}

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ "$version" == 0.* ]] || {
  echo 'Beta releases must use a 0.x.y version.' >&2
  exit 1
}
tag="v$version"
notes="docs/RELEASE_NOTES_$version.md"
test -f "$notes"

gh release create "$tag" "$dmg" --repo MochiLog/MochiLog-Mac \
  --target "$(git rev-parse HEAD)" --title "MochiLog Mac $version Beta" \
  --notes-file "$notes" --prerelease

sparkle_bin="Build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
test -x "$sparkle_bin/generate_appcast"
mkdir -p Build/AppcastArchives
cp "$dmg" Build/AppcastArchives/MochiLog-Mac-Beta.dmg
cp "$notes" Build/AppcastArchives/MochiLog-Mac-Beta.md
"$sparkle_bin/generate_appcast" --maximum-deltas 0 \
  --ed-key-file "$key" \
  --download-url-prefix "https://github.com/MochiLog/MochiLog-Mac/releases/download/$tag/" \
  -o Build/AppcastArchives/appcast.xml Build/AppcastArchives
grep -q 'sparkle:edSignature=' Build/AppcastArchives/appcast.xml || {
  echo 'Sparkle did not sign the update archive.' >&2
  exit 1
}
"$sparkle_bin/sign_update" --ed-key-file "$key" Build/AppcastArchives/appcast.xml
"$sparkle_bin/sign_update" --verify --ed-key-file "$key" Build/AppcastArchives/appcast.xml
cp Build/AppcastArchives/appcast.xml appcast.xml
grep -q "<sparkle:version>$build</sparkle:version>" appcast.xml
git add appcast.xml
git commit -m "Publish signed Sparkle feed for $version beta"
git push origin main

curl -fsSL "https://raw.githubusercontent.com/MochiLog/MochiLog-Mac/main/appcast.xml" \
  -o Build/AppcastArchives/published-appcast.xml
"$sparkle_bin/sign_update" --verify --ed-key-file "$key" \
  Build/AppcastArchives/published-appcast.xml
