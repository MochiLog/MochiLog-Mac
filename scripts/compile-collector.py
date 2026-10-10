#!/usr/bin/env python3
"""Compile the maintained device library and adapters; include their runtime."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--sign-identity')
    args = parser.parse_args()
    if args.jobs < 1 or sys.version_info < (3, 13):
        raise SystemExit('Python 3.13+ and at least one compiler job are required.')
    root = Path(__file__).resolve().parents[1]
    output = root / 'Build' / 'Nuitka'
    output.mkdir(parents=True, exist_ok=True)
    executable = 'pymobiledevice3.exe' if sys.platform == 'win32' else 'pymobiledevice3'
    command = [sys.executable, '-m', 'nuitka', '--mode=standalone',
               '--output-dir=' + str(output), '--output-filename=' + executable,
               '--jobs=' + str(args.jobs), '--low-memory', '--assume-yes-for-downloads',
               '--python-flag=isolated', '--python-flag=safe_path', '--python-flag=unbuffered',
               '--include-package=pymobiledevice3', '--include-package-data=pymobiledevice3',
               '--include-package=pytun_pmd3', '--include-package-data=pytun_pmd3',
               '--include-module=DirectRsd', '--include-module=BatterySnapshot',
               '--include-module=CollectorBuildInfo',
               '--user-package-configuration-file=' + str(root / 'scripts/collector.nuitka-package.config.yml'),
               '--report=' + str(output / 'compilation-report.xml')]
    # The CLI queries its own version dynamically. Nuitka handles dependency
    # metadata at the import sites; build-only distributions must not be bundled.
    command.append('--include-distribution-metadata=pymobiledevice3')
    if sys.platform == 'win32':
        command += ['--msvc=latest', '--windows-console-mode=force']
    elif sys.platform == 'darwin' and args.sign_identity:
        command += ['--macos-sign-identity=' + args.sign_identity, '--macos-sign-notarization']
    command.append(str(root / 'CollectorEntry.py'))
    subprocess.run(command, cwd=root, check=True)
    distribution = output / 'CollectorEntry.dist'
    if not (distribution / executable).is_file():
        raise SystemExit('Compiled standalone collector was not produced.')
    # Keep paths identical for native callers. Replace the entire folder to avoid
    # accidentally retaining files from an older compiler/dependency version.
    destination = root / 'Build' / 'Collector'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(distribution, destination)
    subprocess.run([sys.executable, str(root / 'scripts/test-compiled-collector.py'),
                    str(destination / executable)], cwd=root, check=True)


if __name__ == '__main__':
    main()
