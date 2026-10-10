#!/usr/bin/env python3
"""Prove the collector works away from Python and from the source/build tree."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    source = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='mochilog-compiled-smoke-') as temporary:
        folder = Path(temporary)
        shutil.copytree(source.parent, folder / 'Collector')
        executable = folder / 'Collector' / source.name
        home = folder / 'home'
        home.mkdir()
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home),
               'NO_COLOR': '1', 'TERM': 'dumb', 'PYTHONHOME': str(folder / 'missing-python'),
               'PYTHONPATH': str(folder / 'missing-modules')}
        if os.name == 'nt':
            system = os.environ['SystemRoot']
            env.update({'SystemRoot': system, 'WINDIR': system, 'PATH': system + r'\System32',
                        'TEMP': temporary, 'TMP': temporary, 'USERPROFILE': str(home),
                        'APPDATA': str(home), 'LOCALAPPDATA': str(home)})
        started = time.monotonic()
        result = subprocess.run([str(executable), '--mochilog-build-info'], cwd=folder,
                                env=env, check=True, capture_output=True, text=True, timeout=90)
        info = json.loads(result.stdout)
        assert info['compiler'] == 'nuitka', info
        assert all(info['compiledModules'].values()), info
        assert info['pymobiledevice3'] == '11.19.1', info
        for command in ([], ['battery-snapshot'], ['direct-rsd'], ['usbmux'], ['lockdown'], ['remote'], ['crash']):
            subprocess.run([str(executable), *command, '--help'], cwd=folder, env=env,
                           check=True, capture_output=True, timeout=90)
        print(json.dumps({'standaloneSmoke': 'passed', 'buildInfo': info,
                          'seconds': round(time.monotonic() - started, 3),
                          'bytes': sum(p.stat().st_size for p in source.parent.rglob('*') if p.is_file())}))


if __name__ == '__main__':
    main()
