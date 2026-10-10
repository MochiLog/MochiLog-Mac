"""Bounded diagnostics bridge failures must retain the acquisition stage."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

remote = types.ModuleType("pymobiledevice3.remote")
remote.userspace_tunnel = types.SimpleNamespace()
service = types.ModuleType("pymobiledevice3.remote.tunnel_service")
service.create_core_device_tunnel_service_using_remotepairing = None
reports_module = types.ModuleType("pymobiledevice3.services.crash_reports")
reports_module.CrashReportsManager = None
with patch.dict(sys.modules, {
    "pymobiledevice3": types.ModuleType("pymobiledevice3"),
    "pymobiledevice3.remote": remote,
    "pymobiledevice3.remote.tunnel_service": service,
    "pymobiledevice3.services": types.ModuleType("pymobiledevice3.services"),
    "pymobiledevice3.services.crash_reports": reports_module,
}):
    spec = importlib.util.spec_from_file_location("direct_bridge", Path(__file__).parents[1] / "DirectRsd.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)


class DiagnosticBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def scan(self, listings, tunnel_error=None):
        closed = []
        class Tunnel:
            async def aopen(self):
                if tunnel_error: raise tunnel_error
                return object()
            async def aclose(self): closed.append(True)
        class Reports:
            async def __aenter__(self): return self
            async def __aexit__(self, *_): pass
            async def ls(self, path, depth):
                result = listings[path]
                if isinstance(result, Exception): raise result
                return result
        args = argparse.Namespace(udid="synthetic", host="192.0.2.1", port=49152, action="scan")
        output = io.StringIO()
        try:
            with patch.object(bridge.userspace_tunnel, "UserspaceRsdTunnel", lambda **_: Tunnel(), create=True), \
                 patch.object(bridge, "CrashReportsManager", lambda _: Reports()), contextlib.redirect_stdout(output):
                await bridge.run(args)
            return json.loads(output.getvalue())
        finally:
            self.assertEqual(closed, [True], "Diagnostic tunnel was not closed")

    async def test_empty_root_is_not_successful_zero(self):
        with self.assertRaisesRegex(RuntimeError, "diagnostic root listing failed"):
            await self.scan({"/": []})

    async def test_tunnel_timeout_has_stage(self):
        with self.assertRaisesRegex(RuntimeError, r"RemotePairing tunnel failed \(TimeoutError\)"):
            await self.scan({}, TimeoutError())

    async def test_unavailable_accessory_preserves_host(self):
        name = "/Retired/Analytics-2026-10-10-090007.ips.ca.synced"
        result = await self.scan({"/": ["/Retired", "/ProxiedDevice-abc"], "/Retired": [name],
            "/ProxiedDevice-abc/Retired": TimeoutError(), "/ProxiedDevice-abc": TimeoutError()})
        self.assertIn({"path": name, "source": None}, result["files"])

if __name__ == "__main__":
    unittest.main()
