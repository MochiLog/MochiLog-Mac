# Mac 1.0.2 release verification — 2026-11-18

## Source and package

- Product source: `5ccec382d8dcbbe51a5c1e3ddb1300635123cbfa`, version 1.0.2 (40). Includes the transfer changes in [the audit](TRANSFER_AUDIT_2026-11-18.md) and the pymobiledevice3 11.58.0 API/CLI compatibility changes in [the library update](DEVICE_LIBRARY_UPDATE_2026-11-18.md).
- Built locally with Fastlane using the compiled standalone collector. The collector was reused only after checking its Python sources, configuration and dependency pins against the compiled revision; the final expanded CLI smoke test also passed.
- Developer ID signed app and DMG, with accepted notarization and stapled tickets. Final app submission: `7a803773-8d59-4cc5-bc23-7b238a0a6418`; DMG submission: `0fdad404-fb94-40ba-9c32-f567588c59c1`.
- Public DMG: 119,193,708 bytes; SHA-256 `4477a944627c8c78e84036225ed84c0d5fbcfd2254898eed84a6fd0acce1afe9`.
- A fresh anonymous download matched the local artifact. Public-key verification passed for both the Sparkle archive signature and the signed update feed retrieved from public main. The mounted DMG app passed strict/deep code-signature and stapled-ticket checks and reports version 1.0.2 (40).

## Tests

- Native encrypted transfer, replay/downgrade rejection, ACK, duplicate preflight, source ownership, protected untransferred logs, support export and guarded subprocess tests passed. Slow progressing writes and stalled writes are tested separately; see the audit for the LAN self-connection limitation.
- The isolated compiled collector passed without an external Python environment, including the real-library direct-provider contract and current discovery/trust/crash command shapes.
- With the new compiled helper, a physical iPad returned its current battery registry, root and Retired file lists, and a complete current-day analysis file (109,838 bytes). The file has 183 lines and battery markers; this is not classified by size alone. Values, identifiers and log contents remain private.
- This is not a fresh end-to-end mobile encrypted-transfer test, or a physical slow-link test. The iPhone was away; no new iPhone collection success is claimed.

## Physical app and publication

- Updated `/Applications/MochiLog Mac.app` to 1.0.2 (40), after backing up the previous app and private state. The pairing store stayed byte-identical during installation; a fresh native snapshot retained both paired identities.
- Native UI self-check passed hide-window, minimize and hide-app release/recreation cycles, plus the setting that retains the screen. The original setting was restored. This is automated physical app validation, not manual visual inspection.
- Published [v1.0.2](https://github.com/MochiLog/MochiLog-Mac/releases/tag/v1.0.2) with Japanese/English release notes, DMG, checksum and signed appcast. The root update feed was committed separately after validating the public DMG.
- Raw diagnostics, state, rollback archive and runtime evidence remain private under the ignored investigation directory. No OS trust, router, VPN or firewall settings were changed.

[Signed CI run 44237289998](https://github.com/MochiLog/MochiLog-Mac/actions/runs/44237289998) also passed on the same product source: native/Python tests, compiled helper, signed app/DMG notarization and signed update-feed preparation. The public binary above is the locally built and notarized artifact, not a claim of byte equality with a separate CI build.
