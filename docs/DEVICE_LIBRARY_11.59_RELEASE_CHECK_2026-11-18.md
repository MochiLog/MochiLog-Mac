# Device library release check — 2026-11-18 (1.0.3)

Official PyPI reports pymobiledevice3 11.59.0, published 2026-11-18. Both PC apps now pin that version.

Reviewed the [official release](https://github.com/doronz88/pymobiledevice3/releases/tag/v11.59.0) and the complete v11.58.0...v11.59.0 source comparison. The update adds the network lockdown heartbeat, keeps mobdev2 tunnel clients alive, improves network errors and adds a direct-address CLI option. The remote pairing TLV implementation moved into `remote.pair_setup`; the existing tunnel API re-exports the symbols it uses. The direct RemotePairing provider factory and the current-battery adapter keep their existing public API contract. No new PIN pairing workflow is enabled by MochiLog in this release.

Existing discovery, trust, crash-list and crash-pull argument shapes are checked against the actual compiled library. The isolated collector gate also checks imports, crypto, dynamic dependencies, the real direct-provider factory and cleanup without using a user's device or pairing data. Native protocol tests remain required. Complete signed/compiled release results are recorded separately after they pass.

Users do not install Python. The Windows installer and notarized Mac app bundle the complete compiled collector.
