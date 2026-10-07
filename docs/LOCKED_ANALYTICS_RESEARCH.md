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

No keys, certificates, pairing records, diagnostic contents, phone UDIDs or addresses are included in this memo. Research scripts and command result files remain outside tracked source. The probe did not flush/move reports or use destructive pull options.

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
