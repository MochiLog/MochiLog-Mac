# Daily collection review — 2026-10-14

## Evidence

Reviewed locally copied native PC snapshots and daily activity logs. Raw logs, addresses and pairing identities remain in ignored Build directories. The Mac log contained 422 iPad AFC FILE_OPEN status-10 failures between 09:00 and 19:01 JST. Windows repeatedly tried a stale socket-peer address while its most recent sealed LAN hint had aged out of the one-hour preferred list.

At 19:06–19:07 JST the Mac saved current iPhone, Watch and iPad reports. At 19:11 JST it stopped automatic collection for both hosts until the next log day. Daily-completion logic was working and is unchanged. Resource snapshots showed stable retained app memory during this sample, rather than another runaway diagnostic reader. Mobile logs received by PCs did not contain a current-day archive at review time; this review does not claim full on-device coverage.

## Changes

- Coordinate file reads in Swift/C#, leaving the maintained Python transport unchanged. Direct collection probes one file per host/accessory before its remaining batch; legacy collection stops that source for the poll after an explicit AFC permission denial.
- Preserve failed and held files as pending. Only the actually failed file gets the existing persisted retry time. Prefer untried files within the same day on a subsequent poll; more recent days still come first.
- Keep Watch sources independent. A permission error is not treated as proof of device lock or a reason to discard a file.
- Allow sealed mobile LAN hints aged 1–24 hours as unverified fallbacks, after a recent OS-authenticated endpoint and before the socket peer. Reject stale hints beyond 24 hours. IP addresses never replace OS pairing identity verification.
- Trace requested files before helper execution, source gates and held counts. A held acquisition remains incomplete.

## Verification

Native regression fixtures cover host denial with a successful Watch read, retry rotation, pending recovery, split batch index mapping, precise error matching, route ordering/expiry and existing manual/address isolation. Full protocol suites also cover encryption, replay rejection, duplicate preflight, ACK, retention and daily host/Watch stopping. Release build and physical-PC installation results are recorded below after validation.

Mac validation: full native suite passed, including the source gate and retry-rotation fixtures. Release 0.2.31 (34) built with one compiler job; unchanged Nuitka helper inputs were verified byte-for-byte before reuse. The app and DMG were both accepted by Apple's notary service and stapled. Physical Mac installation/startup produced a fresh native snapshot with both paired identities preserved and no active orphan helper. Real current-day acquisition was observed on 0.2.30 before the fix; the later 0.2.31 startup correctly retains the daily stop. No claim is made that a new physical transfer occurred after installation while the daily stop was active.
