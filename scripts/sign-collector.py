#!/usr/bin/env python3
"""Sign every bundled Mach-O leaf before sealing the helper and outer app."""
import argparse
from pathlib import Path
import subprocess
import sys

MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
         b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
         b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--entitlements', required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    helper = directory / 'mochilog-collector'
    if not helper.is_file():
        raise SystemExit('Compiled collector is missing.')
    binaries = []
    for path in sorted(directory.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MAGIC:
                    binaries.append(path)
    if helper not in binaries:
        raise SystemExit('Collector is not a Mach-O executable.')
    binaries.remove(helper)
    binaries.append(helper)
    for index, path in enumerate(binaries, 1):
        print(f'Signing collector {index}/{len(binaries)}: {path.relative_to(directory)}', flush=True)
        command = ['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp',
                   '--sign', args.identity]
        if path == helper:
            command += ['--entitlements', args.entitlements]
        subprocess.run([*command, str(path)], check=True, timeout=120)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)],
                       check=True, timeout=30)


if __name__ == '__main__':
    main()
