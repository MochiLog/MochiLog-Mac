"""Offline build verification, without pairing, sockets or user device data."""

import importlib
from importlib import metadata
import json
import plistlib
from pathlib import Path


async def verify_direct_provider_contract():
    """Exercise the real library's factory and cleanup without opening a socket."""
    from contextlib import asynccontextmanager
    from types import SimpleNamespace
    import DirectRsd
    import BatterySnapshot
    from pymobiledevice3.remote import tunnel_service, userspace_tunnel

    class ProbeReached(Exception):
        pass

    services = []

    class Service:
        closed = 0

        async def close(self):
            self.closed += 1

        @asynccontextmanager
        async def start_tcp_tunnel(self):
            raise ProbeReached()
            yield  # Defines the async context; no network stack is created.

    async def create(remote_identifier, hostname, port, autopair=True):
        assert (remote_identifier, hostname, port, autopair) == (
            "fixture-device",
            "192.0.2.1",
            49152,
            False,
        )
        service = Service()
        services.append(service)
        return service

    old_direct = DirectRsd.create_core_device_tunnel_service_using_remotepairing
    old_remote = tunnel_service.create_core_device_tunnel_service_using_remotepairing
    default_factory = userspace_tunnel._create_no_root_tunnel_provider
    DirectRsd.create_core_device_tunnel_service_using_remotepairing = create
    tunnel_service.create_core_device_tunnel_service_using_remotepairing = create
    args = SimpleNamespace(udid="fixture-device", host="192.0.2.1", port=49152, action="verify")
    try:
        try:
            await DirectRsd.run(args)
            raise AssertionError("Diagnostic bridge did not enter its direct provider")
        except RuntimeError as error:
            assert isinstance(error.__cause__, ProbeReached), type(error.__cause__)
        try:
            await BatterySnapshot.read_direct(args)
            raise AssertionError("Battery bridge did not enter its direct provider")
        except ProbeReached:
            pass
        assert len(services) == 2 and all(service.closed == 1 for service in services)
        assert userspace_tunnel._create_no_root_tunnel_provider is default_factory
    finally:
        DirectRsd.create_core_device_tunnel_service_using_remotepairing = old_direct
        tunnel_service.create_core_device_tunnel_service_using_remotepairing = old_remote


def main():
    import asyncio

    asyncio.run(verify_direct_provider_contract())
    names = [
        "DirectRsd",
        "BatterySnapshot",
        "pymobiledevice3.__main__",
        "pymobiledevice3.services.diagnostics",
        "pymobiledevice3.services.crash_reports",
        "pymobiledevice3.remote.tunnel_service",
        "pymobiledevice3.remote.userspace_tunnel",
    ]
    compiled = {}
    for name in names:
        module = importlib.import_module(name)
        compiled[name] = hasattr(module, "__compiled__")
    # Exercise DLL loads, platform provider imports, TLS roots, encryption and
    # dynamically generated schemas used by the maintained library.
    import pytun_pmd3
    import certifi
    from construct import Struct, Int32ul
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from BatterySnapshot import encode_registry

    assert Path(certifi.where()).is_file(), "TLS roots missing"
    schema = Struct("value" / Int32ul)
    assert schema.parse(schema.build({"value": 42})).value == 42
    cipher = ChaCha20Poly1305(bytes(range(32)))
    nonce = bytes(range(12))
    encrypted = cipher.encrypt(nonce, b"collector-fixture", b"build-test")
    assert cipher.decrypt(nonce, encrypted, b"build-test") == b"collector-fixture"
    sample = {"CycleCount": 42, "ExternalConnected": False, "Fixture": 2**63 + 5}
    assert plistlib.loads(encode_registry(sample)) == sample
    print(
        json.dumps(
            {
                "compiler": "nuitka"
                if hasattr(main, "__compiled__") or "__compiled__" in globals()
                else "python",
                "compiledModules": compiled,
                "pymobiledevice3": metadata.version("pymobiledevice3"),
                "offlineChecks": [
                    "platform-provider",
                    "tls-roots",
                    "schema",
                    "crypto",
                    "typed-plist",
                    "direct-provider-contract",
                ],
            },
            sort_keys=True,
        )
    )
