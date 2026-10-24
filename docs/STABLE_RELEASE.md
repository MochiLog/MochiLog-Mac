# Stable Mac release from CI

1. Set the marketing/build versions and write Japanese and English release notes. Commit and push source before dispatching `.github/workflows/signed-beta.yml` with `prepare_update_feed=true`.
2. Wait for protocol tests, the compiled collector's isolated runtime checks, Developer ID signing, app/DMG notarization, stapling and Gatekeeper assessment to succeed. A successful build alone is insufficient.
3. Download the notarized artifact for that exact run. Confirm the DMG's SHA-256 against its checksum file. Mount it read-only and verify the app version/build, `codesign --verify --deep --strict`, and `xcrun stapler validate` for both app and DMG.
4. Verify the signed update feed and archive without the private key:

   ```sh
   swift scripts/verify-sparkle-release.swift /path/to/appcast.xml /path/to/MochiLog-Mac.dmg 1.0.0 38
   ```

5. Update the installed app and check that existing paired device identities and authenticated transfers remain valid. Keep private state backups and native snapshots outside Git.
6. Create a non-prerelease GitHub release targeting the successful CI source commit. Upload `MochiLog-Mac.dmg`, its SHA-256 file and the signed `appcast.xml`, with `docs/RELEASE_NOTES_VERSION.md` as the description.
7. Only after the release download exists, copy the CI-signed feed byte-for-byte to repository-root `appcast.xml`, commit and push. Do not reformat or edit signed XML. Re-download the public DMG/feed and repeat public-key verification.

The old `publish-beta-release.sh` is restricted to 0.x beta builds; do not use it for 1.x stable releases. The existing Sparkle public key, bundle ID, application path and saved pairing state remain unchanged.

Mobile App Store publication is separate: prepare the mobile build/metadata/screenshots, but leave review submission to the user when requested. Do not describe an unapproved mobile or AltStore PAL version as publicly available.
