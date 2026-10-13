#!/usr/bin/env bash
# Shared by local builds, the compiler CI and signed DMG builds.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${MOCHILOG_REUSE_COLLECTOR_FROM:-}" ]]; then
  # Explicit local reuse only. CI keeps compiling the complete distribution.
  # Native-only changes must not rebuild a large unchanged Python dependency.
  python3 - "$MOCHILOG_REUSE_COLLECTOR_FROM" <<'PY'
import pathlib, subprocess, sys
reference = sys.argv[1]
files = ['CollectorEntry.py', 'DirectRsd.py', 'BatterySnapshot.py',
         'CollectorBuildInfo.py', 'requirements-build.txt',
         'scripts/collector.nuitka-package.config.yml', 'scripts/compile-collector.py']
for name in files:
    previous = subprocess.run(['git', 'show', f'{reference}:{name}'],
                              check=True, capture_output=True).stdout
    if previous != pathlib.Path(name).read_bytes():
        raise SystemExit(f'Collector reuse refused: {name} changed since {reference}')
if not pathlib.Path('Build/Collector/mochilog-collector').is_file():
    raise SystemExit('Collector reuse refused: no completed distribution')
pathlib.Path('Build/reused-collector-from.txt').write_text(reference + '\n')
PY
  python3 scripts/test-compiled-collector.py Build/Collector/mochilog-collector
  exit 0
fi
python_bin="${MOCHILOG_PYTHON_BIN:-python3.13}"
jobs="${MOCHILOG_COMPILER_JOBS:-1}"
"$python_bin" -c 'import sys; assert sys.version_info[:2] == (3, 13), "Use Python 3.13 to build the pinned collector"; assert "pyenv" not in sys.base_prefix, "Use Homebrew or python.org Python, not pyenv, for Nuitka standalone builds"'
mkdir -p Build
if [[ ! -x Build/NuitkaVenv/bin/python ]]; then
  "$python_bin" -m venv Build/NuitkaVenv
fi
Build/NuitkaVenv/bin/python -c 'import sys; assert sys.version_info[:2] == (3, 13) and "pyenv" not in sys.base_prefix, "Remove Build/NuitkaVenv and recreate it with a supported Python 3.13"'
Build/NuitkaVenv/bin/python -m pip install --disable-pip-version-check -r requirements-build.txt
Build/NuitkaVenv/bin/python scripts/compile-collector.py --jobs "$jobs" 2>&1 | tee Build/collector-build.log
