"""Offline build verification, without pairing, sockets or user device data."""
import importlib
from importlib import metadata
import json
import plistlib
from pathlib import Path


def main():
    names = ['DirectRsd', 'BatterySnapshot', 'pymobiledevice3.__main__',
             'pymobiledevice3.services.diagnostics',
             'pymobiledevice3.services.crash_reports',
             'pymobiledevice3.remote.tunnel_service',
             'pymobiledevice3.remote.userspace_tunnel']
    compiled = {}
    for name in names:
        module = importlib.import_module(name)
        compiled[name] = hasattr(module, '__compiled__')
    # Exercise DLL loads, platform provider imports, TLS roots, encryption and
    # dynamically generated schemas used by the maintained library.
    import pytun_pmd3
    import certifi
    from construct import Struct, Int32ul
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from BatterySnapshot import encode_registry
    assert Path(certifi.where()).is_file(), 'TLS roots missing'
    schema = Struct('value' / Int32ul)
    assert schema.parse(schema.build({'value': 42})).value == 42
    cipher = ChaCha20Poly1305(bytes(range(32)))
    nonce = bytes(range(12))
    encrypted = cipher.encrypt(nonce, b'collector-fixture', b'build-test')
    assert cipher.decrypt(nonce, encrypted, b'build-test') == b'collector-fixture'
    sample = {'CycleCount': 42, 'ExternalConnected': False, 'Fixture': 2 ** 63 + 5}
    assert plistlib.loads(encode_registry(sample)) == sample
    print(json.dumps({'compiler': 'nuitka' if hasattr(main, '__compiled__') or '__compiled__' in globals() else 'python',
                      'compiledModules': compiled, 'pymobiledevice3': metadata.version('pymobiledevice3'),
                      'offlineChecks': ['platform-provider', 'tls-roots', 'schema', 'crypto', 'typed-plist']}, sort_keys=True))
