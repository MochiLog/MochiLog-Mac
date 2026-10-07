# Analytics access after first unlock (2026-10-07)

## Scope and conclusion

The requested state is **after first unlock (AFU), followed by screen lock**. Before-first-unlock after reboot is deliberately excluded. This investigation does not remove a passcode, reset trust, re-pair a device, modify protection settings, or delete diagnostic files.

On the paired iPhone 17 running iOS 27.2, no working locked-state Analytics-content acquisition route was verified. Metadata remains visible while the file body is protected. A separate live-battery diagnostic snapshot succeeded shortly after relocking; see the [detailed reproduction recipe](LOCKED_BATTERY_SNAPSHOT_RECIPE.md). That snapshot is not the daily file. These are results for the tested device, pairing records and OS versions, not proof that every service or future authentication route is impossible.

## Live evidence

Host: macOS 27.2 (26B5101f), pymobiledevice3 11.19.1 (both packaged helper and local research environment), Xcode 27.2 beta 2 for the comparison. Tests ran around 19:46–19:50 JST. `devicectl device info lockState` before and between probes reported `passcodeRequired: true` and `unlockedSinceBoot: true`.

| Route | Observation | Interpretation |
| --- | --- | --- |
| Current native RSD, crash-report AFC shim | Root and Retired listings succeeded. A 12,880-byte Analytics file and the 21,327,604-byte `Analytics-2026-10-07-090004.ips.ca.synced` could be statted, but read-only FILE_OPEN returned AFC PERM_DENIED (10). | Connection/discovery and metadata access succeeded; content acquisition failed. |
| Native RSD with `include_escrow_bag=True` | A nonempty saved RemotePairing unlock key exists. RSDCheckin/StartService returned `EscrowFailure`. No file body was received. | This stored-key authentication attempt failed. Key presence alone does not prove that it is accepted. |
| Classic paired Wi-Fi lockdownd, no escrow | A paired client connected through mobdev2 discovery, but the crash-report service connection terminated. | This route did not produce a readable file. The connection failure alone is not proof of a lock-policy rejection. |
| Classic paired Wi-Fi lockdownd, with escrow | Classic escrow information exists; connection to the requested service port was refused. | No successful acquisition; transport/service failure cannot establish why the escrow route failed. |
| Apple CoreDevice `systemCrashLogs` | File listing marked the 21.3 MB file Readable. Copy failed with CoreDevice 7000 → remoteservices 11001 → remote openat POSIX 1 (EPERM). | The Readable metadata flag is not a guarantee of locked-state content access. The underlying failure occurred on the device. |

No keys, certificates, pairing records, diagnostic contents, phone UDIDs or addresses are included in this memo. Raw command results remain outside tracked source. The follow-up independent research client is tracked under `scripts/research/`; it contains no device data. The probe did not flush/move reports or use destructive pull options.

## Independent implementation follow-up

At the user's request, an independent read-only client was implemented in C and Python's standard library. It does not import, execute or link pymobiledevice3 or libimobiledevice. Protocol formats were studied from their upstream source; this is not an independent invention of Apple's protocols. See [research client instructions](../scripts/research/USAGE.md).

The code implements macOS XPC tunnel assertions for an **already paired** device, HTTP/2 framing, RemoteXPC encoding/decoding and RSD discovery, length-prefixed plist check-in, classic lockdownd sessions with mutually authenticated TLS and an exact device-certificate pin, and read-only AFC stat/open/read/close. The tunnel uses Apple's installed `remotepairingd`/`remoted` services. It is not a new implementation of the OS's trust or tunnel cryptography. `nettop` and `remotectl dumpstate` supply the existing OS endpoint and host identity; neither performs file acquisition for the remote-mode client.

Live results on the same AFU-locked iPhone, approximately 20:07–20:30 JST:

| Independent route | Result |
| --- | --- |
| C tunnel + custom HTTP/2/RemoteXPC + plain RSD check-in + custom AFC | Peer identifier verified, service started, file stat reported 21,327,604 bytes. Read-only FILE_OPEN returned status 10 (PERM_DENIED). Repeated at 20:28 with the same result. No file body was copied. |
| Same transport, existing RemotePairing unlock credential | RSDCheckin was accepted, but StartService returned EscrowFailure. This confirms that this stored credential did not authorize this service request. |
| Classic TCP, existing usbmuxd trust record | StartSession and pinned mutual TLS succeeded; the device identifier matched. StartService was accepted but connection to its requested service port was refused. |
| Stock `remotectl netcat` bridge | Could not connect to the named diagnostic service. The independent socket implementation above succeeded further, so this bridge failure is not the basis of the locked-file conclusion. |
| Independent service inventory | Found `com.apple.osanalytics.logTransfer`, advertising UsesRemoteXPC. No supported read-only Analytics-content request was established for it. Its presence is not acquisition success. |

The Mac's installed `com.apple.osanalytics.osanalyticshelper.plist` restricts its logTransfer endpoint with `com.apple.ReportCrash.antenna-access` and a `compute-node` device-type limit. That is **Mac-side policy**, not proof of the iPhone service's access policy. Do not request or forge private entitlements, send guessed mutation/submission RPCs, or claim this alternate route works based on a service name alone.

The iPhone was reported `passcodeRequired: true`, `unlockedSinceBoot: true` before and after these independent probes. No trust reset or new pairing was performed. A while-unlocked control was not established in this early batch; the later control below succeeded. Developer Mode-off and Windows checks remain required if a working acquisition route is later found.

Nine offline tests cover fragmented plist/HTTP2 replies, invalid/oversized/truncated frames, unexpected stream IDs, known XPC fixtures, denied and incomplete AFC reads, and private atomic output publication without overwriting existing files. The C helper builds with `-Wall -Wextra -Werror`. This is research tooling, not a replacement for the packaged collector; no product behavior or release changed.

## Additional routes and credential identity

The user excluded backup and iPhone Mirroring from the intended solution. No backup was created and no Mirroring authentication or collection session was established. Those routes are not a fallback for automatic collection in this investigation.

Further independent probes, approximately 20:51–21:24 JST:

| Route | Evidence and limit |
| --- | --- |
| Native OS tunnel after a longer locked interval | CreateAssertion returned `com.apple.dt.RemotePairingError` 1016. CoreDevice independently reported that the device had not been unlocked recently. This occurs before RSD or file access. It is separate from the earlier AFC body denial. The latest call could not return lock-state fields; the last successful state measurement at 20:30 was AFU-locked. No exact unlock-age limit was measured. |
| Classic diagnostics_relay, GasGauge query | Existing paired mutual TLS and peer verification still worked. StartService returned PasswordProtected, with and without the existing classic EscrowBag. The query itself was not reached; this does not establish that battery metric values are inaccessible under every locked-state condition. |
| Classic file_relay availability with escrow | Paired TLS worked, but StartService returned PasswordProtected. No Sources request or compressed archive was requested. [Apple documents](https://support.apple.com/guide/security/physical-pairing-model-security-secadb5b6434/web) a signed-profile requirement for file_relay; the [upstream service header](https://github.com/libimobiledevice/libimobiledevice/blob/master/include/libimobiledevice/file_relay.h) names the classic service and warns about staging left behind by undrained archive requests. This is not an ordinary app route to promise users. |
| osanalytics.logTransfer custom RemoteXPC transport | A transport-only negotiation probe was implemented with no guessed service RPC. The live attempt was blocked by native tunnel error 1016 before reaching this service; no conclusion about its body-read permission can be drawn. |
| Existing OS RemotePairing credential | The native paired-device snapshot already contained `remoteUnlockHostKey`. It was read through a private binary parent pipe, kept in process memory, and compared with the saved tool credential. They **differed**. No key bytes, length, hash or device identifier were printed or saved. No key-creation or refresh request was made. |

Different keys do not by themselves mean corruption or expiry: the OS and a separate tool can have distinct pairing identities. The earlier experiment combined an OS native tunnel/RSD context with the tool's saved unlock credential, so EscrowFailure cannot rule out an identity-matched credential. The independent client supports `--checkin os-escrow` using only the already-present OS snapshot key. Its first live attempt was blocked at tunnel creation with 1016. The user subsequently unlocked and relocked the phone, permitting the controlled comparison below. Do not claim that collecting a key removes future recent-unlock requirements.

`CopyRemoteUnlockHostKeyRequest` and remote-unlock support were found in the installed framework's protocol metadata. That request is deliberately not sent because obtaining a missing credential may involve initialization. The read-only snapshot route fails if no existing key is present. Private entitlement changes, blind assertion-flag experiments, trust resets, credential regeneration and security-policy changes were not performed.

The live-battery alternatives return metric field availability only, with `daily_analytics_acquired: false`. Even a future successful GasGauge/IORegistry snapshot would not be the daily Analytics log, and would not preserve its history, Watch reports or all battery metrics. No record format or parser was changed. Holding an already-open handle also remains untested; [CompleteUnlessOpen](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeunlessopen) is one protection class, not evidence that these Analytics files use it or that a new file can be opened after lock.

The expanded tooling has **13 passing offline tests**, including private credential-pipe bounds/missing-key handling, absence of credential/serial data in stage output, and an alternate transport bootstrap that sends no service operation. Product collection still requires unlock as before; Windows live verification has not occurred in this follow-up.

## Unlocked control and fresh AFU-locked comparison

The user unlocked the phone, then explicitly relocked it. The state check before the control returned `passcodeRequired: false`, `unlockedSinceBoot: true`. Before the locked-file probes, after them, and after the battery snapshot probes it returned `passcodeRequired: true`, `unlockedSinceBoot: true`. Tests ran approximately 22:02–22:08 JST.

| Probe | Observation | Limit |
| --- | --- | --- |
| Unlocked, plain check-in, independent AFC | Complete read of the same 21,327,604-byte Analytics file, 36,136 lines, SHA-256 computed; private temporary body discarded. | Positive control: the independent reader and report path work when unlocked. |
| Unlocked, existing OS key attached to check-in | RSDCheckin and StartService responses had no reported error; connection closed before the first complete AFC reply. | This closure also occurs unlocked, so it cannot be attributed to screen-lock policy or claimed as a working authenticated file channel. |
| AFU-locked, existing OS key attached | Same check-in responses, then connection closed before the first complete AFC reply. | Key submitted successfully at the protocol stage, but no file body or metadata was acquired on this channel. |
| AFU-locked, plain check-in, independent AFC | Stat still returned 21,327,604 bytes; FILE_OPEN again returned PERM_DENIED (10). | The identical body is readable unlocked and denied locked. Changing the client library did not remove this denial. |
| AFU-locked, plain check-in, GasGauge | Status Success; numeric CycleCount and FullChargeCapacity fields present. | Current diagnostic snapshot only. Field names logged; raw numeric values and identities not persisted. |
| AFU-locked, plain check-in, IORegistry / IOPMPowerSource | Status Success; numeric AppleRawMaxCapacity, CurrentCapacity, CycleCount, DesignCapacity, FullChargeCapacity, MaxCapacity and NominalChargeCapacity present. | Current diagnostic snapshot only; units, precision and equality with daily Analytics values unverified. |
| AFU-locked, existing OS key, GasGauge | Check-in responses arrived, then connection closed before a complete diagnostic reply. | Plain check-in is the successful snapshot route; do not imply the OS key enabled it. |
| osanalytics.logTransfer | Service port discovered; normal RemoteXPC bootstrap timed out. No service-specific request sent. | Transport negotiation remains unverified, not evidence of a definitive permission rejection. |
| Remote file_relay availability | Plain RSDCheckin/StartService completed and a connection was available. No Sources request or archive requested. | Service availability is not permission to collect an archive. No daily content acquisition proven. |

The detailed [locked battery snapshot recipe](LOCKED_BATTERY_SNAPSHOT_RECIPE.md) records the exact requests, commands, fields and state checks for future work. It may be a candidate for a separate snapshot feature after further validation; it is not an implementation of unattended daily-log collection. Successful snapshots were obtained only within minutes of relocking. The later final state-check attempt timed out; it did not return new state fields or change the earlier successful before/after snapshot checks. No long-lock threshold was measured.

## Why escrow remains a candidate, not a solution

[Apple's physical pairing model](https://support.apple.com/guide/security/physical-pairing-model-security-secadb5b6434/web) distinguishes services requiring a recently unlocked device from services requiring a currently unlocked device. It does not guarantee locked-state access to Analytics files. [Apple's escrow keybag description](https://support.apple.com/guide/security/keybags-for-data-protection-sec6483d5760/web) explains authorized backup/sync without repeated passcode entry; that is not a guarantee for crash-report AFC.

pymobiledevice3 supports passing an escrow bag to classic StartService, and an existing RemotePairing `remote_unlock_host_key` to [RSDCheckin](https://github.com/doronz88/pymobiledevice3/blob/v11.19.1/pymobiledevice3/remote/remote_service_discovery.py). Its CrashReportsManager/AfcService does not enable this by default. These are different credentials and must not be substituted for each other or copied into MochiLog's app-pairing JSON.

The unlocked and relocked comparisons above are now complete for the existing OS snapshot key. The next investigation must explain its post-check-in channel closure before treating that credential route as usable. Preserve the existing pairing and key storage. A successful read while unlocked is only a control; require a nonempty complete file and locked state before and after the final read. A working result must then be checked with Developer Mode off and on Windows' userspace RSD transport before changing product promises. The successful plain-check-in battery snapshots need separate long-lock, platform, units and accuracy checks.

Keeping an already-open file handle across screen lock is a separate unverified experiment. It cannot by itself solve daily collection of files that did not exist when the device was unlocked. Do not keep sessions indefinitely or advertise unattended acquisition on that basis.

Other routes are not substitutes: Apple documents that file_relay requires an Apple-signed profile; ordinary app-container access does not expose system Analytics files; the current Tailscale app protocol only transfers already queued files (see [transport research](DIAGNOSTIC_TRANSPORT.md)).

## Collector implications

- Never mark a file collected from its name, size, an empty local destination, or a zero process exit status alone. The upstream `pull` uses `ignore_errors=True`; a denied FILE_OPEN can therefore yield an incomplete local result instead of a successful body transfer.
- Treat protection/permission errors and incomplete reads as retryable acquisition failures, not permanent non-battery exclusions. Existing deferred classification remains necessary.
- Do not infer that every log is unreadable: the earlier [September experiment](https://github.com/MochiLog/MochiLog/blob/experiment/mac-log-transfer/docs/mac-wireless-log-probe.md) read a small Jetsam report while Analytics was denied.
- No runtime behavior or release was changed by this research. Windows shares the acquisition protocol, but the live locked-state probes in this memo ran from Mac, not Windows.

## Safe reproduction

Use the currently discovered paired device identifier in place of `<device>`; never re-pair automatically during the probe.

```sh
xcrun devicectl device info lockState --device '<device>' --timeout 15
xcrun devicectl device info files --device '<device>' --domain-type systemCrashLogs --subdirectory Retired --no-recurse --search Analytics --timeout 20
xcrun devicectl device copy from --device '<device>' --domain-type systemCrashLogs --source 'Retired/<existing-Analytics-file>' --destination '/tmp/mochilog-locked-probe.ips' --timeout 20
xcrun devicectl device info lockState --device '<device>' --timeout 15
```

Keep the raw file and command output private. Do not use crash-report deletion, a pull tool's default erase mode, security-policy changes, or a reboot as part of this AFU experiment.
