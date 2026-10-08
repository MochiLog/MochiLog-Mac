"""Read the battery registry through pymobiledevice3; leave interpretation to native code.

This bridge owns only device connectivity, API invocation and lossless plist
transport over a private pipe. Swift/C# select display fields, validate values,
flatten nested data, calculate revisions and timestamp the result. No registry
values are written to diagnostic logs or disk.
"""

import argparse
import asyncio
import logging
import plistlib
import sys
from typing import Any

MAX_REPLY_BYTES = 1_048_576


def encode_registry(registry: dict[str, Any]) -> bytes:
    """Preserve plist integers, booleans, bytes and dates without interpreting them."""
    if not isinstance(registry, dict) or not registry:
        raise ValueError("Battery registry unavailable")
    payload = plistlib.dumps(registry, fmt=plistlib.FMT_XML, sort_keys=True,
                            aware_datetime=True)
    if len(payload) > MAX_REPLY_BYTES:
        raise ValueError("Battery reply exceeds transport limit")
    return payload


async def read_registry(provider: Any) -> dict[str, Any]:
    """The maintained library owns the Apple diagnostics service protocol."""
    from pymobiledevice3.services.diagnostics import DiagnosticsService

    async with DiagnosticsService(provider) as diagnostics:
        return await asyncio.wait_for(diagnostics.get_battery(), timeout=12)


async def read_direct(arguments: argparse.Namespace) -> dict[str, Any]:
    """Use an explicitly configured or authenticated peer IP, without re-pairing."""
    from pymobiledevice3.remote import userspace_tunnel
    from pymobiledevice3.remote.tunnel_service import (
        create_core_device_tunnel_service_using_remotepairing,
    )

    async def direct_provider(serial, autopair, remotepairing_fallback=True):
        provider = await create_core_device_tunnel_service_using_remotepairing(
            arguments.udid, arguments.host, arguments.port, autopair=False
        )
        return provider, None

    # pymobiledevice3's default provider discovers via Bonjour. A direct IP
    # also works where multicast discovery is unavailable (e.g. Tailscale).
    userspace_tunnel._create_no_root_tunnel_provider = direct_provider
    tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=arguments.udid, autopair=False)
    try:
        provider = await asyncio.wait_for(tunnel.aopen(), timeout=20)
        return await read_registry(provider)
    finally:
        await tunnel.aclose()


async def run(arguments: argparse.Namespace) -> dict[str, Any]:
    """Prefer the native Mac route, then use a known peer as a bounded fallback."""
    fallback_host = getattr(arguments, "fallback_host", None)
    if not arguments.host and fallback_host:
        local = argparse.Namespace(udid=arguments.udid, host=None, port=arguments.port)
        try:
            return await asyncio.wait_for(run(local), timeout=8)
        except Exception:
            direct = argparse.Namespace(udid=arguments.udid, host=fallback_host,
                                        port=arguments.port)
            return await run(direct)

    if arguments.host:
        return await read_direct(arguments)

    if sys.platform == "darwin":
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel

        tunnel = NativeRemotedTunnel(serial=arguments.udid)
        try:
            provider = await asyncio.wait_for(tunnel.aopen(), timeout=20)
            return await read_registry(provider)
        finally:
            await tunnel.aclose()

    from pymobiledevice3.lockdown import create_using_usbmux

    provider = await create_using_usbmux(serial=arguments.udid, autopair=False)
    try:
        return await read_registry(provider)
    finally:
        await provider.close()


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--host")
    parser.add_argument("--fallback-host")
    parser.add_argument("--port", type=int, default=49152)
    arguments = parser.parse_args(argv)

    # Library exceptions can contain entire replies. Never print their content.
    logging.getLogger().setLevel(logging.CRITICAL)
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    try:
        registry = asyncio.run(asyncio.wait_for(run(arguments), timeout=40))
        payload = encode_registry(registry)
    except Exception:
        print('{"error":"battery_unavailable"}')
        return
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main(sys.argv[1:])
