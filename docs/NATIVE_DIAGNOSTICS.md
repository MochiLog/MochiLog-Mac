# Native Mac diagnostics

Mac 0.2.30 generates diagnostic snapshots inside Swift, without a shell or an external log reader. A single background task saves NativeDiagnostics/current.json and one latest snapshot per local calendar day, once per minute. Resource measurements enter the ordinary activity log every five minutes.

Schema 1 explicitly describes app/build/OS versions, local timestamps, own process resident and peak resident memory, active helpers, per-device connection candidates, collection results and recent activity. It never serializes arbitrary runtime objects, pairing secrets or live battery values, and has no OS UDID field. Activity messages may still contain private device identifiers. IDs, names and network addresses are private diagnostics; redact them before posting public issues.

## Bounds

- Snapshots: 32 devices, 50 recent messages, 256 KiB total; variable text and endpoint lists are bounded before encoding.
- File reads are capped before decoding: endpoint/collection caches 8 KiB, received mobile reports 16 KiB, recent events 1 MiB and OS diagnostics 2 MiB. Corrupt oversized files are not decoded.
- Daily snapshots use the existing activity-log retention, initially 30 days; deleting debug logs clears snapshots too.
- Support attachments are prepared off the UI thread. Complete daily archives are copied as files, without loading and re-encoding their contents in memory. The existing archive exchange format and protocol remain compatible.

For automated inspection, copy the existing NativeDiagnostics/current.json directly and parse it locally. Do not launch another process to aggregate the same caches and logs.

## Helper supervision

GuardedProcess starts each helper with native posix_spawn in its own process group and drains stdout/stderr through nonblocking pipes. The same monotonic deadline covers the process and its output. Defaults are 8 MiB stdout / 1 MiB stderr; current battery requests use 1 MiB / 64 KiB and retain their 45-second deadline. Pairing has a 190-second outer deadline and 64 KiB per output stream; its cancel button signals the same owner.

Timeout, cancellation, output overflow or a sampled helper resident-memory measurement above 1 GiB terminates the process group with SIGKILL and reaps the direct child. Normal completion also removes descendants that still hold pipes open. Normal app termination stops active groups. The memory guard is sampled every 250 ms; it is not a kernel-enforced allocation limit. Apple system services are not part of the owned group.

References: [Apple posix_spawn](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html), [Apple poll](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/poll.2.html).

## Validation on 2026-10-14

The native tests encoded a roughly 580 KiB synthetic event source into a 26,373-byte report, retained the latest 50 events, bounded 1,000 devices to 32 and rejected unbounded DTOs before serialization. After warmup, 1,000 exports increased measured resident memory by 49,152 bytes in the initial local run. This is a regression check, not a guarantee about indefinite runtime.

Tests also covered oversized cache reads, atomic current/daily files, retention/deletion, ignored SIGTERM, deadline, cancellation, stdout/stderr overflow, the memory guard, and a descendant retaining the stdout pipe after its parent exited. All passed. The existing encrypted transfer, replay, ACK, host/Watch, duplicate preflight and daily archive-exchange tests passed too.

## Foreground UI lifetime

The opt-out ReleaseUiWhenHidden preference defaults to enabled. WindowMemoryManager observes only the main window and app hide/unhide notifications. The foreground CompanionView branch is unmounted while hidden, minimized or closed; reopening creates a new screen on the last selected page. CompanionModel and its authenticated server/collection timers retain their original app-level lifetime. Forms and per-view caches are discarded. With the preference off, this explicit teardown is disabled.

Screen state creation/destruction and allocator relief are logged. After a completed teardown, malloc_zone_pressure_relief asks the native allocator to return free cached pages; it does not promise that shared framework/graphics caches disappear. The explicit local --verify-ui-memory check verifies the actual screen-state lifetime across three hide/reopen cycles and the disabled preference, writes a small typed report and restores the prior preference.

The macOS 27.2 integration check also exercises window hiding, minimizing and app hiding on the overview, settings and current-battery pages. The child hosting controller is created outside the enclosing SwiftUI update transaction so its graph has an independent lifetime. A minimal local probe reproduced retained state with the native `.link` button style; text actions use a custom SwiftUI ButtonStyle to avoid that path. No private AppKit/SwiftUI API is used.

Final physical-Mac report at 2026-10-14 05:00 JST: all three screen-state release/recreation checks passed (overview/window hide, settings/minimize, current battery/app hide), and disabling teardown retained the same state. Window minimization is checked after its actual animation completes. All saved preferences are restored. Resident memory includes shared framework/graphics caches and need not immediately drop by the amount of freed screen allocations.

## Incomplete directory listings (2026-10-17)

Collection summaries now include an additive listingFailures count. A directory that could not be checked is distinct from a failed file download or a successfully checked empty directory. Partial listings retain available reports, stay incomplete and are retried by the existing scheduler. Per-directory errors and final counts enter the activity log. Older saved summaries without the new field still decode; the snapshot schema and encrypted mobile protocol are unchanged.
