# Diagnostic collection versus app transfer

MochiLog Mac uses two independent connections:

1. Apple's paired-device diagnostic service lets the Mac read Analytics files from an unlocked iPhone or iPad. The current collector uses `pymobiledevice3 crash` over a working local wireless pairing.
2. MochiLog's authenticated app connection sends files already queued on the Mac to the iPhone or iPad. This connection supports the local network and Tailscale, including cellular access when the app is running.

Do not treat a successful app connection over Tailscale as evidence that Apple's diagnostic service is reachable. The app's sandbox cannot read the system Analytics directory and therefore cannot substitute for that service.

## iOS/iPadOS 27 cellular/Tailscale experiment (2026-09-26)

- Both the iPhone and iPad were already paired with the Mac and were reachable over Tailscale on cellular. The app transfer succeeded on iPhone; an iPad transfer was still running on a throttled cellular plan when this result was recorded.
- A TCP connection from the Mac to the iPhone's Tailscale address on lockdownd port 62078 was accepted, but a valid `QueryType` request was reset by the device. `pymobiledevice3.create_using_tcp(..., autopair=False)` failed the same way. This also happened while the iPhone had local Wi-Fi enabled.
- The iPad refused TCP connections to port 62078 at its Tailscale address.
- The Mac's native RemotePairing browse reported the iPhone's remembered device record as unavailable over cellular, and starting a native tunnel timed out.
- A debug-only iPhone app probe to `127.0.0.1:62078` timed out. The probe was removed after testing; the standard debug app was reinstalled.

These observations rule out using the current Tailscale route for automatic **new** system Analytics collection. Tailscale carries the app protocol, but it does not grant access to Apple's device diagnostic service. Do not advertise cellular collection or silently count a successful app transfer as a collection. Retain queued files and retry collection when a supported local OS-pairing route becomes available. A user can still share Analytics files from Settings to MochiLog while away from the Mac.
