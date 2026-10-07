# Analytics access after first unlock (2026-10-07)

## Scope and conclusion

The requested state is **after first unlock (AFU), followed by screen lock**. Before-first-unlock after reboot is deliberately excluded. This investigation does not remove a passcode, reset trust, re-pair a device, modify protection settings, or delete diagnostic files.

On the paired iPhone 17 running iOS 27.2, no working locked-state Analytics-content acquisition route was verified. Metadata remains visible while the file body is protected. This is a result for the tested device, pairing records and OS versions, not proof that every service or future authentication route is impossible.

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

At the user's request, an independent read-only client was implemented in C and Python's standard library. It does not import, execute or link pymobiledevice3 or libimobiledevice. Protocol formats were studied from their upstream source; this is not an independent invention of Apple's protocols. See [research client instructions](../scripts/research/README.md).

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

The iPhone was reported `passcodeRequired: true`, `unlockedSinceBoot: true` before and after the final independent probes. No trust reset or new pairing was performed. A while-unlocked control and a freshly accepted unlock credential were not established in this follow-up. Developer Mode-off and Windows checks also remain required if a working acquisition route is later found.

Nine offline tests cover fragmented plist/HTTP2 replies, invalid/oversized/truncated frames, unexpected stream IDs, known XPC fixtures, denied and incomplete AFC reads, and private atomic output publication without overwriting existing files. The C helper builds with `-Wall -Wextra -Werror`. This is research tooling, not a replacement for the packaged collector; no product behavior or release changed.

## Why escrow remains a candidate, not a solution

[Apple's physical pairing model](https://support.apple.com/guide/security/physical-pairing-model-security-secadb5b6434/web) distinguishes services requiring a recently unlocked device from services requiring a currently unlocked device. It does not guarantee locked-state access to Analytics files. [Apple's escrow keybag description](https://support.apple.com/guide/security/keybags-for-data-protection-sec6483d5760/web) explains authorized backup/sync without repeated passcode entry; that is not a guarantee for crash-report AFC.

pymobiledevice3 supports passing an escrow bag to classic StartService, and an existing RemotePairing `remote_unlock_host_key` to [RSDCheckin](https://github.com/doronz88/pymobiledevice3/blob/v11.19.1/pymobiledevice3/remote/remote_service_discovery.py). Its CrashReportsManager/AfcService does not enable this by default. These are different credentials and must not be substituted for each other or copied into MochiLog's app-pairing JSON.

The next controlled experiment, if the user unlocks the phone, is to validate the existing credential while unlocked, establish whether an authorized fresh RemotePairing unlock credential is needed, and then retry after screen lock. Preserve the existing pairing and key storage. A successful read while unlocked is only a control; require a nonempty complete file and locked state before and after the final read. A working result must then be checked with Developer Mode off and on Windows' userspace RSD transport before changing product promises.

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
