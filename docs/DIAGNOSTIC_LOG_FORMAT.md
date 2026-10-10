# Diagnostic log format 2

This describes support diagnostics, not Apple's battery Analytics files or saved battery records.

## Files

`DebugLogs/YYYY-MM-DD/category-v2-APP_VERSION-BUILD.log` holds one feature's events. The date uses the device's local time zone. Categories: `background`, `local-collection`, `pc-transfer`, `live-battery`, `cloud-sync`, `pairing`, `general`. The iOS root retains the existing `MacTransferDebugLogs` name. Mac and Windows use `DebugLogs`. Unknown messages go to `general`; credentials and QR keys must never be logged.

The first line is `# ` followed by JSON: `type=mochilog-diagnostic-log`, `formatVersion=2`, `category`, `appVersion`, `build`, `createdAt`, `timeZone`, `recordLayout=timestamp | message`. Following lines retain the existing timestamp/message layout. Version/build changes select a new feature file. Do not repeat format metadata on every event.

Unversioned historical logs are format 1. Migrated legacy events are stored in `category-v1-legacy.log`, with unknown app/build metadata. Never relabel old events as format 2.

## Older peers and support

`YYYY-MM-DD.log` remains the append-only compatibility stream used by existing encrypted diagnostic archive exchange, day selection and support attachments. Each new format/app/build segment has one header with category `combined`. Earlier unversioned bytes remain untouched. Never sort, regenerate or prepend this file: remote peers retain byte offsets. Existing limits, manifests, snapshot refresh and authenticated encryption are unchanged. The feature files are local diagnostic organization, not a new unencrypted network protocol.

The compatibility copy costs extra storage; both copies follow the same retention and user-deletion policy. There is no independent long-lived duplicate archive. Delete the daily stream and the same-date feature directory together. Legacy `.log` files remain readable without an eager migration.

## Background investigation

Normal application launch logs the actual OS state and whether protected data is available. Each scheduled OS wake logs a `wakeID`, task identifier, lock/protection status and application state. Completion logs the same ID, elapsed milliseconds, success and cancellation. Expiration logs that ID and why checkpoints were retained. A registered or submitted request is not evidence of an actual OS wake. Natural OS frequency remains a separate real-device measurement.

## Regression checks

The mobile pairing test script, Mac transfer test script and Windows protocol tests check feature separation and header version, legacy byte-prefix preservation, append-only chunk offsets, single compatibility headers and safe deletion. Shared Swift archive implementations in the mobile and Mac repos use the same source. Windows implements the same file/header contract in C#.


## 2026-10-10 beta verification

Version 0.2.23: [final CI](https://github.com/MochiLog/MochiLog-Mac/actions/runs/38058755225) passed the archive/viewer compatibility tests and native application build. The physical PC was updated from the published release and generated format-version-2 feature files. Artifact SHA-256: `7f3ce8e85284e0178f07fc390097e4ce015b3e7b2466ec27829ba6fe048ab9c3`. Received mobile archives remain append-only; filtering is read-only and never resets transfer offsets. The viewer preserves legacy and unsupported future records in All. Final physical viewer interaction was not automated; the read-only viewer logic was covered by tests.
