# Device library update — 2026-11-18

Checked the official [PyPI package](https://pypi.org/project/pymobiledevice3/): 11.58.0, released November 17, 2026.
Mac had pinned 11.19.1, while Windows pinned 11.55.0. Both now pin 11.58.0.

The new userspace tunnel expects a `TunnelProvider` object and exposes the public per-session `provider_factory` argument.
Returning the old plain tuple would break after the package update. Both diagnostics and current-battery adapters now use the public hook instead of replacing a private module-global factory.

`CollectorBuildInfo` exercises the real library’s factory and cleanup path using synthetic services that stop before opening any socket.
It checks the selected device/address/port, `autopair=False`, both adapters reaching their provider, cleanup exactly once, and the default provider staying unchanged.
The compiled, isolated smoke test requires this check too, so compilation or CLI help alone cannot pass the release gate.
The smoke test reads the expected package version from the requirements pin instead of an obsolete hardcoded version.

Before future releases, check the official package for an update, review changed connection APIs, refresh the pin in both PC repositories, and run native protocol tests, Python bridge tests and the isolated compiled collector test.
These are developer build requirements; users do not install Python.

Source-environment bridge tests and the real-library contract check passed locally. Signed app/DMG, isolated collector and Windows installer results must be recorded separately once completed.
