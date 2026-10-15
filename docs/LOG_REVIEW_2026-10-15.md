# Daily review — 2026-10-15

## Evidence

Copied existing native snapshots and daily logs locally. Raw diagnostics, addresses and device identifiers remain in ignored Build directories.

The Mac log shows a concrete timer overlap: iPhone and Watch reads failed at 19:26:25/26 JST, setting retries for 19:31:25/26. At 19:31:24 the next listing had already finished, so those files were held. Other reports were readable in that same collection. The required host/Watch reports were eventually saved at 19:36:25/26; daily collection stopped at 19:41. This establishes an avoidable missed attempt, without establishing exactly when the user arrived or unlocked the device.

The iPad's authenticated Mac listings contained no current-day battery candidates during the sampled day. Older iPad reports were accessible again at 19:31. This does not prove whether analytics sharing is enabled or why Apple has not generated a current report. Windows attempted its cached OS-authenticated endpoint and socket-peer fallback but recorded no successful collection today at review time. Being outside or having an unavailable device is not, by itself, an application defect.

Snapshots at 19:53 JST showed roughly 74 MB Mac resident memory and 197 MB Windows private memory, with about 5.4 MB Windows managed memory. These snapshots do not show another runaway reader. Current-day mobile archives were not available in the received Mac archive directory, so this is primarily a PC-side review.

## Change

Failed downloads now persist an elapsed attempt timestamp, rather than another future five/thirty-minute deadline. The outer five-minute scheduler remains responsible for automatic retry cadence. Source permission gates remain limited to the current collection. The next probe selects an untried or least recently attempted eligible report per source, including across dates; subsequent reports retain daily priority. Failed and held files never enter the delivered ledger.

Content that was successfully downloaded but cannot yet be classified keeps its existing five/thirty-minute recheck interval. Daily completion, crypto, consent, source identity, ACK and duplicate preflight are unchanged. Old cache deadlines written by previous versions retain their existing expiry; no ambiguous old entry is guessed to be a download failure.

Regression fixtures cover recovery on the immediately following collection without editing the retry ledger, persistent attempt markers, independent content waits, cross-day probe rotation and host/Watch isolation. Both PC implementations use native coordination; Python transport sources are unchanged.

Validation: the full native suite passed, including recovery without editing failure deadlines, independent downloaded-content waits, cross-day probe selection, source isolation, encrypted transfer, replay/ACK and daily completion. The final run had no compiler warnings. Mac 0.2.32 (35) was built in Release with one compiler job; unchanged compiled-helper inputs were checked before reuse. Both app and DMG were accepted and stapled. Physical installation used graceful app termination; the new native snapshot preserved both paired identities.
