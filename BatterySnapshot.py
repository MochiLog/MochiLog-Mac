"""Current battery values through the maintained pymobiledevice3 API.

No raw registry dump, serial number, history file, or record import is emitted.
The wrapper only chooses an existing paired transport and filters its response.
"""
import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import logging
import math
import sys

FIELDS = {
    'CycleCount': (0, 100000),
    'DesignCapacity': (1, 200000),
    'FullChargeCapacity': (1, 200000),
    'NominalChargeCapacity': (1, 200000),
    'AppleRawMaxCapacity': (1, 200000),
    'CurrentCapacity': (0, 100),
}


def filter_values(raw):
    # Only the selected IOPMPowerSource entry, never recursive arbitrary nodes.
    if not isinstance(raw, dict):
        raise ValueError('No battery entry')
    battery = raw.get('BatteryData')
    if not isinstance(battery, dict):
        battery = {}
    values = {}
    for key, (minimum, maximum) in FIELDS.items():
        value = (battery.get(key, raw.get(key)) if key not in ('CycleCount', 'CurrentCapacity')
                 else raw.get(key))
        if (type(value) in (int, float) and math.isfinite(value)
                and minimum <= value <= maximum and float(value).is_integer()):
            values[key] = int(value)
    if type(raw.get('IsCharging')) is bool:
        values['IsCharging'] = raw['IsCharging']
    if not any(key in values for key in ('CycleCount', 'DesignCapacity', 'FullChargeCapacity',
                                         'NominalChargeCapacity', 'AppleRawMaxCapacity')):
        raise ValueError('Battery capacity fields unavailable')
    return values


def snapshot(raw):
    values = filter_values(raw)
    revision = hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'version': 1, 'values': values, 'revision': revision,
            'acquiredAt': datetime.now(timezone.utc).isoformat(timespec='seconds')}


async def read(provider):
    from pymobiledevice3.services.diagnostics import DiagnosticsService
    async with DiagnosticsService(provider) as diagnostics:
        return snapshot(await asyncio.wait_for(diagnostics.get_battery(), 12))


async def run(args):
    if args.host:
        from pymobiledevice3.remote import userspace_tunnel
        from pymobiledevice3.remote.tunnel_service import create_core_device_tunnel_service_using_remotepairing
        async def direct_provider(serial, autopair, remotepairing_fallback=True):
            provider = await create_core_device_tunnel_service_using_remotepairing(
                args.udid, args.host, args.port, autopair=False)
            return provider, None
        userspace_tunnel._create_no_root_tunnel_provider = direct_provider
        tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=args.udid, autopair=False)
        try:
            return await read(await asyncio.wait_for(tunnel.aopen(), 20))
        finally:
            await tunnel.aclose()
    if sys.platform == 'darwin':
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
        tunnel = NativeRemotedTunnel(serial=args.udid)
        try:
            return await read(await asyncio.wait_for(tunnel.aopen(), 20))
        finally:
            await tunnel.aclose()
    from pymobiledevice3.lockdown import create_using_usbmux
    provider = await create_using_usbmux(serial=args.udid, autopair=False)
    try:
        return await read(provider)
    finally:
        await provider.close()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--udid', required=True)
    parser.add_argument('--host')
    parser.add_argument('--port', type=int, default=49152)
    args = parser.parse_args(argv)
    # Library exceptions can embed a full registry reply. Never log them.
    logging.getLogger().setLevel(logging.CRITICAL)
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    try:
        result = asyncio.run(asyncio.wait_for(run(args), 40))
    except Exception:
        print(json.dumps({'error': 'battery_unavailable'}))
        return
    print(json.dumps(result, allow_nan=False, separators=(',', ':')))


if __name__ == '__main__':
    main(sys.argv[1:])
