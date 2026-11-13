# Pairing diagnostics and support exports (2026-11-13)

The mobile app could show a QR handshake error without persisting it. The companion also lacked sufficient invitation/handshake audit events. Split feature logs were saved locally, but support exports still copied only the daily combined stream. A small attachment count therefore did not, by itself, prove lost categories. It could conceal a separate missing-event problem.

## Implementation

- Record invitation creation, listener state and bounded per-session handshake outcomes. Known active-session failures distinguish expiry, invalid/replaced public keys, protocol or device conflicts, rejected confirmation and failed credential/replay-state persistence. Keys, PINs, proofs and full QR payloads stay out of these events. Random public session IDs correlate both sides.
- Allow the support sheet without a selected app-paired phone. This is necessary to diagnose pairing failures before authenticated diagnostic exchange can start.
- `SupportLogExport` snapshots split feature files, daily compatibility streams and diagnostic JSON for the selected day plus the preceding two days, without modifying originals. Missing/empty/unreadable/budget-omitted files and unavailable remote sources enter a schema-1 manifest. Empty placeholder attachments are not created.
- Exports run off the UI thread. Payload files have a 12 MiB / 96-file budget, plus the small manifest. Copying uses fixed-size snapshots and 64 KiB chunks; it never decodes all logs into a String. Symbolic files/day directories are skipped. File copies preserve original headers, versions and bytes.
- Remote peers still exchange the complete combined daily stream. That stream includes all categories, but the original physical feature files may exist only on their source device; the manifest explains this distinction. If pairing never completed, export the PC's data on the PC itself.

The wire protocol and saved keys are unchanged. Existing pairings and append-only archive offsets remain compatible. The mobile pairing receiver separately fixes a reproduced newline/EOF wait defect; the original reporter's timeout has not been conclusively attributed to that defect.

## Verification

- `bash scripts/test-transfer-protocol.sh` covers split export, missing files, symbolic-file rejection and budget manifests, then the encrypted transfer/replay/archive suite, QR challenge and rejected/correct confirmation audit, secret exclusion and support export before pairing.
- Release macOS build with Xcode 27.2 RC passes without signing or distribution.
- Equivalent Windows export and protocol tests and the full Windows Release build pass on the physical Windows host. No USB trust, stored production pairing or driver reset is required for these isolated tests.

The export tests create synthetic fixtures and do not send email. Mail-client/provider delivery limits remain separate from the app's attachment generation.

## ZIP and timeout follow-up

The mail composer now receives exactly one ZIP instead of the individual payload files. The ZIP preserves the prepared manifest and original log names/bytes. ZIPFoundation 0.9.20 is pinned and its MIT license is bundled and visible in the licenses screen. The app does not start a shell/Python process for compression. Synthetic ZIPs are independently checked for CRC and exact UTF-8 contents using Python only in the test harness.

The timeout investigation additionally found stale QR hint/fallback problems in mobile and a Mac QR readiness gap. Mac now publishes Wi-Fi-prioritized hints and the actual bound port, withholds QR while the listener is unavailable, and records credential-persistence start/end timing and bounded response-write failures. The new unavailable status is translated in all eight supported languages. Offline-listener and actual-port checks pass alongside the existing protocol suite.

The detailed cross-platform timeout-path audit is in the mobile repository's docs/PAIRING_TIMEOUT_AUDIT_2026-11-13.md. It distinguishes reproduced symptoms from reporter-specific unknowns. Source changes have not been signed, notarized, installed or released by this verification.
