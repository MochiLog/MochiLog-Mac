# Mac 1.0.3 release verification — 2026-11-18

## Source and verification

Product source: `d07821fbe03183c36101695d38247c5383ee0ee8`, version 1.0.3 (41). Includes [the pairing/transfer investigation](PC_LINK_STABILITY_2026-11-18.md) and the checked [pymobiledevice3 11.59.0 update](DEVICE_LIBRARY_11.59_RELEASE_CHECK_2026-11-18.md).

Built locally using Fastlane and Xcode 27.2 RC. Python bridge tests, real-library provider/cleanup contract and the complete native encrypted transfer/support/archive/process-supervision suite passed. The freshly compiled collector passed isolated execution without an external Python installation, both before and after hardened signing. All seven checked modules are compiled and the embedded library reports 11.59.0.

Developer ID signing, strict/deep signature checks, Gatekeeper assessment and app/DMG notarization/stapling passed. App submission: `a900ebfb-58b4-46aa-96a0-d19c5893cc96`; DMG: `f9107718-f621-4b93-9290-2069f1f44f45`. Public DMG: 122,824,131 bytes, SHA-256 `1fc7a01c14ebfb424c871ce150f99f3985b9f923b5ec5262e33e44909bf8a050`.

## Update-feed verification correction

The first release-verification attempt rejected an otherwise correctly signed feed containing both 1.0.3 and 1.0.2: the developer verifier incorrectly concatenated version fields across items while retaining only the first enclosure. It now verifies the first (latest) item independently. Six synthetic-key tests cover a valid two-version feed, wrong expected version, old-first order, wrong URL, modified archive and modified signed feed. All passed. The verifier/workflow correction is a developer-tool change after the product build and is not presented as a rebuilt runtime.

## Physical installation and publication

Mounted the DMG read-only and verified the packaged app before replacing only `/Applications/MochiLog Mac.app`. Retained the previous app and private pairing-state backup. The pairing file was byte-identical during installation; host identity and both physical-device identities remained present after launch. The new app's native hide/minimize/hide-app release/recreation check and the disabled-setting retention check passed; original preferences were restored. A fresh native snapshot reports 1.0.3 (41).

Published [v1.0.3](https://github.com/MochiLog/MochiLog-Mac/releases/tag/v1.0.3), with Japanese/English notes, notarized DMG, portable checksum filename and signed update feed. A fresh anonymous DMG download matched the verified package. After the public asset existed, committed the signed feed byte-for-byte to main; the public feed and public DMG both passed public-key verification.

This is automated validation of the actual Mac application, not a fresh physical phone-transfer test or a real-device permission-denial/grant test. The new permission UI and mobile transfer recovery cases were checked separately as described in the investigation. Raw diagnostics, state and rollback evidence stay in ignored `Build/release-1.0.3/`.
