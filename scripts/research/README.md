# Independent locked-state diagnostic probe

Developer research only. This is a read-only protocol client, not MochiLog's shipped collector. It targets an already trusted iPhone after first unlock, then screen lock. Before-first-unlock after reboot is excluded. See [results and limits](../../docs/LOCKED_ANALYTICS_RESEARCH.md).

## Build and run

Build the small macOS C/XPC helper using a local compiler/SDK:

```sh
mkdir -p Build/research
xcrun clang -fblocks -Wall -Wextra -Werror scripts/research/native_tunnel.c -o Build/research/native_tunnel
python3 -I -B scripts/research/test_independent_diagnostics.py
```

The Python client uses only the standard library and its sibling wire codec. `-I` isolates it from user Python packages; `-B` avoids bytecode artifacts. No virtual environment, pip install, or pymobiledevice3 executable is required. The helper relies on macOS's existing trusted tunnel services and private message formats, which may change between OS releases. This is Mac-hosted research, not Windows transport support or clean-host production qualification.

Use the existing paired UDID and an existing non-session Analytics path. Substitutions below are placeholders; do not enter them literally.

```sh
python3 -I -B scripts/research/independent_diagnostics.py \
  --udid '<paired-device-UDID>' \
  --file '/Retired/Analytics-YYYY-MM-DD-HHMMSS.ips.ca.synced' \
  --checkin plain
```

Use `--inventory` to list diagnostic service names without requesting a report body. Use `--checkin escrow --pair-record '/private/existing-remote-record.plist'` to test an existing authorized RemotePairing credential. An existing record may also be found in the previous tool's local data directory; reading that saved credential does not execute the tool. No key is created, refreshed or printed. Do not interchange classic EscrowBag and RemotePairing unlock credentials.

Classic paired TCP comparison:

```sh
python3 -I -B scripts/research/independent_diagnostics.py \
  --mode classic --host '<current-discovered-device-address>' \
  --udid '<paired-device-UDID>' \
  --file '/Retired/Analytics-YYYY-MM-DD-HHMMSS.ips.ca.synced'
```

Classic mode reads Apple's existing trust record from usbmuxd if no local record is supplied. The address must be freshly discovered; a fixed address is not a product design. `--mode os-service` is a stock `remotectl netcat` comparison that failed on the tested setup. The default remote mode implements discovery, check-in and AFC itself.

## Interpretation and data handling

- Record lock state independently before and after a live test, for example with `xcrun devicectl device info lockState --device '<paired-device-UDID>' --timeout 15`. Xcode is an external state-check tool, not the acquisition client. A read while unlocked alone does not validate AFU-locked collection.
- A metadata size, accepted service request, empty destination or zero-error listing is not success. Require `file_complete`, the complete nonempty body, byte count and SHA-256. A refused open ends with a nonzero exit status and its AFC status.
- Without `--output`, the body, if readable, is kept in a private temporary file and discarded. With `--output '/private/new-report.ips'`, a full read is staged with mode 0600, synced and atomically published without replacing an existing file or symlink. Failed/truncated reads never create a final copy. Raw Analytics data can be sensitive; keep any explicit copy private and remove it after examination.
- Requests never include Pair, Unpair, Unlock, mover/flush, file write, erase or protection-setting changes. Sessions are closed and the helper's tunnel assertion is released at exit; the overall deadline is 120 seconds and packet/file limits are bounded.
- The native helper's address is sent only through its private parent pipe. Run it through the Python client; its direct stdout is not a sanitized diagnostic log. Pairing keys, certificates, full discovery metadata, phone identifiers and addresses are never included in the client's stage events.
- This tooling does not parse battery metrics or import records, and does not establish a new supported collection promise.

Protocol references: [libimobiledevice AFC](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/afc.c), [lockdownd](https://github.com/libimobiledevice/libimobiledevice/blob/master/src/lockdown.c), [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd/blob/master/src/libusbmuxd.c), and MIT-licensed [pymobiledevice3 v11.19.1 RemoteXPC](https://github.com/doronz88/pymobiledevice3/tree/v11.19.1/pymobiledevice3/remote). These are wire-format references; their libraries are not imported, linked or executed by this client.
