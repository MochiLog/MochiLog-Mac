# 0.2.34 beta distribution — 2026-10-19

This maintenance release publishes the formatted source described in [CODE_FORMATTING.md](CODE_FORMATTING.md).

- Source: `4c6df515870347db4888092e08a27369ad92e875`.
- [Signed Release build, native collector compilation and notarization](https://github.com/MochiLog/MochiLog-Mac/actions/runs/39141703965): succeeded.
- [GitHub beta release](https://github.com/MochiLog/MochiLog-Mac/releases/tag/v0.2.34): published with the DMG and SHA-256 file.
- Version `0.2.34`, build `37`, bundle ID `net.ryuya-dev.MochiLog.mac`, Developer ID team `FZ35ZF3CZV` were checked in the mounted DMG.
- App and DMG signatures and stapled notarization tickets were verified. Gatekeeper accepted the app as `Notarized Developer ID`.
- The signed appcast and DMG were independently verified with the public Ed25519 key already embedded in the app. The public GitHub asset digest matched the CI artifact.
- DMG size: `122132289` bytes.
- SHA-256: `76c70f094d6b33703f5b974dbd4b0ce5929feec3dc34f4db02f70c5c54a3ccbc`.

The compiled collector report recorded 2,551 C cache misses in this run. This was a full native rebuild; do not describe it as a measured cache speedup. The native protocol suite and standalone collector checks ran in CI, including the completed signed helper.

The CI-generated `UpdateFeed/appcast.xml` is copied without editing to the repository root. Both its embedded feed signature and its DMG signature must validate with the existing public key. No local private signing key is required to publish this already signed CI artifact.

Downloaded packages and raw validation evidence remain in the ignored `Build/beta-release-0.2.34/` directory. The temporary read-only verification volume was ejected after inspection.
