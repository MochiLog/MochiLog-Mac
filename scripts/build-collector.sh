#!/usr/bin/env bash
# Shared by local builds, the compiler CI and signed DMG builds.
set -euo pipefail
cd "$(dirname "$0")/.."
python_bin="${MOCHILOG_PYTHON_BIN:-python3.13}"
jobs="${MOCHILOG_COMPILER_JOBS:-1}"
"$python_bin" -c 'import sys; assert sys.version_info[:2] == (3, 13), "Use Python 3.13 to build the pinned collector"; assert "pyenv" not in sys.base_prefix, "Use Homebrew or python.org Python, not pyenv, for Nuitka standalone builds"'
mkdir -p Build
if [[ ! -x Build/NuitkaVenv/bin/python ]]; then
  "$python_bin" -m venv Build/NuitkaVenv
fi
Build/NuitkaVenv/bin/python -c 'import sys; assert sys.version_info[:2] == (3, 13) and "pyenv" not in sys.base_prefix, "Remove Build/NuitkaVenv and recreate it with a supported Python 3.13"'
Build/NuitkaVenv/bin/python -m pip install --disable-pip-version-check -r requirements-build.txt
compiler_options=(--jobs "$jobs")
if [[ -n "${MOCHILOG_COLLECTOR_SIGN_IDENTITY:-}" ]]; then
  compiler_options+=(--sign-identity "$MOCHILOG_COLLECTOR_SIGN_IDENTITY")
fi
Build/NuitkaVenv/bin/python scripts/compile-collector.py "${compiler_options[@]}"
