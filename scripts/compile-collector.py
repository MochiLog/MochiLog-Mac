#!/usr/bin/env python3
"""Compile the maintained device library and adapters; include their runtime."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=1)
    args = parser.parse_args()
    if args.jobs < 1 or sys.version_info < (3, 13):
        raise SystemExit("Python 3.13+ and at least one compiler job are required.")
    root = Path(__file__).resolve().parents[1]
    output = root / "Build" / "Nuitka"
    output.mkdir(parents=True, exist_ok=True)
    executable = "pymobiledevice3.exe" if sys.platform == "win32" else "mochilog-collector"
    command = [
        sys.executable,
        "-m",
        "nuitka",
        "--mode=standalone",
        "--output-dir=" + str(output),
        "--output-filename=" + executable,
        "--jobs=" + str(args.jobs),
        "--assume-yes-for-downloads",
        "--show-scons",
        "--python-flag=isolated",
        "--python-flag=safe_path",
        "--python-flag=unbuffered",
        "--include-package=pymobiledevice3",
        "--include-package-data=pymobiledevice3",
        "--include-package=pytun_pmd3",
        "--include-package-data=pytun_pmd3",
        "--include-module=DirectRsd",
        "--include-module=BatterySnapshot",
        "--include-module=CollectorBuildInfo",
        "--user-package-configuration-file="
        + str(root / "scripts/collector.nuitka-package.config.yml"),
        "--report=" + str(output / "compilation-report.xml"),
    ]
    low_memory = os.environ.get("MOCHILOG_COMPILER_LOW_MEMORY", "1") != "0"
    cold_build = os.environ.get("MOCHILOG_COLLECTOR_COLD_BUILD", "0") == "1"
    if low_memory:
        command.append("--low-memory")
    if cold_build:
        command.append("--disable-cache=all")
    # The CLI queries its own version dynamically. Nuitka handles dependency
    # metadata at the import sites; build-only distributions must not be bundled.
    command.append("--include-distribution-metadata=pymobiledevice3")
    if sys.platform == "win32":
        command += ["--msvc=latest", "--windows-console-mode=force"]
    command.append(str(root / "CollectorEntry.py"))
    started = time.monotonic()
    print(
        json.dumps(
            {
                "phase": "native-compile",
                "jobs": args.jobs,
                "lowMemory": low_memory,
                "coldBuild": cold_build,
            }
        ),
        flush=True,
    )
    subprocess.run(command, cwd=root, check=True)
    compiled_at = time.monotonic()
    distribution = output / "CollectorEntry.dist"
    if not (distribution / executable).is_file():
        raise SystemExit("Compiled standalone collector was not produced.")
    # Replace the entire native helper folder to avoid
    # accidentally retaining files from an older compiler/dependency version.
    destination = root / "Build" / "Collector"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(distribution, destination)
    subprocess.run(
        [
            sys.executable,
            str(root / "scripts/test-compiled-collector.py"),
            str(destination / executable),
        ],
        cwd=root,
        check=True,
    )
    metrics = {
        "schema": 1,
        "jobs": args.jobs,
        "lowMemory": low_memory,
        "coldBuild": cold_build,
        "compileSeconds": round(compiled_at - started, 3),
        "stageAndVerifySeconds": round(time.monotonic() - compiled_at, 3),
    }
    (root / "Build/collector-build-metrics.json").write_text(
        json.dumps(metrics, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(metrics), flush=True)


if __name__ == "__main__":
    main()
