# Mac 1.0.1 release verification — 2026-11-15

The user requested updated PC distribution artifacts, verified App Store 4.1.0 availability and a customer-reply draft. The original reporter-specific network failure is not claimed to be reproduced or conclusively resolved.

## CI artifact

- Source `984f0961cd78460c21da263158908354997c0e00`, marketing version 1.0.1, build 39. Existing bundle ID, Developer ID team and Sparkle public key are unchanged.
- [Signed/notarized CI run 43712540865](https://github.com/MochiLog/MochiLog-Mac/actions/runs/43712540865) succeeded. The job took 27m30s and passed Python transport, native protocol/support/settings/ZIP, isolated compiled-collector checks, Developer ID signing, app and DMG notarization/stapling, Gatekeeper assessment and signed-feed preparation.
- Final DMG: 129,889,260 bytes, SHA-256 `95bd932ca64c930e150787b76c3c816a4c470c20ee91df09ebd9288e8397b958`.
- Downloaded the exact CI artifact, verified its checksum, mounted it read-only and verified app version/build, deep/strict signatures and app/DMG stapled tickets. Public-key-only verification authenticated both the feed and DMG, including the exact v1.0.1 URL and build 39.
- CI Gatekeeper assessment reported Notarized Developer ID with no override. The physical Mac's assessment also returned that source but noted pre-existing disabled security; no Gatekeeper, firewall or permission setting was changed. Local acceptance alone is not treated as proof of enforcement.
- The artifact retained `UpdateFeed/appcast.xml` as a subdirectory. The first local verifier used a flat path and stopped; a byte-for-byte copy to the expected path allowed the final verifier to pass. Signed XML was not reformatted.

## Physical Mac integration check

- Backed up the previous app, native snapshot, preferences and paired-device store privately. Verified the old process belonged to this installed app and had no active collector children before stopping it. Replaced only `/Applications/MochiLog Mac.app`, using a same-volume staging directory and retaining rollback copies until the checks completed.
- The installed app reports 1.0.1 (39) and passes signature verification. Its paired-device store was unchanged byte-for-byte during replacement.
- The actual installed app's `--verify-ui-memory` integration check passed all three screen release/recreate cycles and the disabled-setting case, restoring previous preferences. A fresh native snapshot reports 1.0.1 (39), the same two physical device identities and confirmed pairings.
- The Mac screen became locked, so computer-use clicks and visual inspection of the new app were unavailable. The app's own bounded integration check and native snapshot ran without unlocking the Mac or reading other applications' UI. This is automated physical-Mac validation, not a claim of manual visual inspection or a new authenticated transfer from physical iPhone/iPad hardware.

## Stable publication

- Published [v1.0.1](https://github.com/MochiLog/MochiLog-Mac/releases/tag/v1.0.1), targeting the exact CI source above. It is non-draft and non-prerelease and includes the notarized DMG, its SHA-256 and the CI-signed feed.
- A fresh anonymous public DMG download passed the same public-key verifier. Only after this public download existed was the exact CI-signed feed copied to root `appcast.xml` for the installed updater. Existing signing keys and pairing identities were preserved.
- Japanese/English release notes are in `RELEASE_NOTES_1.0.1.md`. Logs, private snapshots, state and the unsent customer-reply draft remain ignored under `Build/Release-1.0.1/`. No support email has been sent by this release procedure.
