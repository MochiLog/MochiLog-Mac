"""Direct RemotePairing diagnostic access when Apple Devices omits Wi-Fi discovery.

The mobile app supplies the IP only after its authenticated pairing exchange.
RemotePairing still verifies the device using the OS pairing record for its UDID.
"""

import argparse
import asyncio
import json
import os
import re
import sys

from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.tunnel_service import (
    create_core_device_tunnel_service_using_remotepairing,
)
from pymobiledevice3.services.crash_reports import CrashReportsManager


async def run(arguments: argparse.Namespace) -> None:
    """Connect through the maintained library and perform one bounded operation."""

    async def direct_provider(serial, autopair, remotepairing_fallback=True):
        provider = await create_core_device_tunnel_service_using_remotepairing(
            arguments.udid, arguments.host, arguments.port, autopair=False
        )
        return provider, None

    # The upstream userspace tunnel discovers RemotePairing through Bonjour.
    # Apple Devices on Windows does not expose that advertisement, although the
    # device's authenticated RemotePairing endpoint is reachable by IP.
    userspace_tunnel._create_no_root_tunnel_provider = direct_provider
    tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=arguments.udid, autopair=False)
    phase = "RemotePairing tunnel"
    try:
        rsd = await asyncio.wait_for(tunnel.aopen(), timeout=45)
        phase = "diagnostic service"
        async with CrashReportsManager(rsd) as reports:
            if arguments.action == "verify":
                entries = await asyncio.wait_for(reports.ls("/", depth=1), timeout=30)
                if "/Retired" not in entries:
                    raise RuntimeError("Diagnostic reports are not available")
                print(json.dumps({"verified": True}))
            elif arguments.action == "scan":
                phase = "diagnostic root listing"
                root = await asyncio.wait_for(reports.ls("/", depth=1), timeout=30)
                if not root:
                    raise RuntimeError("Diagnostic root listing is empty")
                files = []
                failures = []
                seen = set()

                async def add_directory(directory, source, cached=None):
                    try:
                        entries = (
                            cached
                            if cached is not None
                            else await asyncio.wait_for(reports.ls(directory, depth=1), timeout=60)
                        )
                    except Exception as error:
                        if len(failures) >= 128:
                            raise ValueError("Diagnostic listing failures exceed limit") from error
                        failures.append(
                            {
                                "directory": directory,
                                "source": source,
                                "error": f"{type(error).__name__}: {error}"[:200],
                            }
                        )
                        return None
                    for entry in entries:
                        # Selection and deduplication belong to Swift/C#. This
                        # bridge only describes files exposed by the library.
                        token = (source, entry)
                        if token not in seen:
                            seen.add(token)
                            files.append({"path": entry, "source": source})
                        if len(files) > 10000:
                            raise ValueError("Diagnostic listing exceeds limit")
                    return entries

                # Read independent directories independently. A failed archive
                # listing must not hide today's current host or Watch reports.
                await add_directory("/", None, root)
                if "/Retired" in root:
                    await add_directory("/Retired", None)
                for entry in root:
                    if re.fullmatch(r"/ProxiedDevice-[a-fA-F0-9]+", entry):
                        phase = "accessory listing"
                        current = await add_directory(entry, entry[1:])
                        retired = entry + "/Retired"
                        if current is None or retired in current:
                            await add_directory(retired, entry[1:])
                print(json.dumps({"files": files, "listingFailures": failures}))
            elif arguments.action == "pull-batch":
                phase = "diagnostic batch download"
                with open(arguments.manifest, encoding="utf-8") as stream:
                    items = json.load(stream)
                if not isinstance(items, list) or len(items) > 1000:
                    raise ValueError("Invalid download manifest")
                results = []
                for index, item in enumerate(items):
                    path = item["path"]
                    if not isinstance(path, str) or not re.fullmatch(
                        r"/(?:ProxiedDevice-[a-fA-F0-9]+/)?(?:Retired/)?Analytics-\d{4}-\d{2}-\d{2}-\d{6}[A-Za-z0-9._-]*\.ips\.ca\.synced",
                        path,
                    ):
                        raise ValueError("Invalid report path")
                    target_dir = os.path.join(arguments.output, str(index))
                    os.makedirs(target_dir, exist_ok=True)
                    try:
                        await asyncio.wait_for(
                            reports.pull(target_dir, entry=path, progress_bar=False),
                            timeout=180,
                        )
                        target = os.path.join(target_dir, path.rsplit("/", 1)[-1])
                        if not os.path.isfile(target):
                            raise FileNotFoundError("Report was not downloaded")
                        results.append({"index": index, "ok": True})
                    except Exception as error:
                        results.append({"index": index, "ok": False, "error": str(error)[:200]})
                print(json.dumps({"results": results}))
    except Exception as error:
        raise RuntimeError(f"{phase} failed ({type(error).__name__}): {error}") from error
    finally:
        await tunnel.aclose()


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("verify", "scan", "pull-batch"))
    parser.add_argument("--udid", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=49152)
    parser.add_argument("--manifest")
    parser.add_argument("--output")
    arguments = parser.parse_args(argv)
    if arguments.action == "pull-batch" and (not arguments.manifest or not arguments.output):
        parser.error("pull-batch requires --manifest and --output")
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(run(arguments))


if __name__ == "__main__":
    main(sys.argv[1:])
