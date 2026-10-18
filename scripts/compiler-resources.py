#!/usr/bin/env python3
"""Choose CI compiler parallelism within the runner's CPU and memory budget."""

import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys


MIB = 1024 * 1024


def physical_memory() -> int | None:
    if sys.platform == "win32":

        class MemoryStatus(ctypes.Structure):
            _fields_ = [
                ("length", ctypes.c_ulong),
                ("load", ctypes.c_ulong),
                *[
                    (name, ctypes.c_ulonglong)
                    for name in (
                        "totalPhysical",
                        "availablePhysical",
                        "totalPageFile",
                        "availablePageFile",
                        "totalVirtual",
                        "availableVirtual",
                        "availableExtendedVirtual",
                    )
                ],
            ]

        status = MemoryStatus()
        status.length = ctypes.sizeof(status)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            return status.totalPhysical
        return None
    if sys.platform == "darwin":
        try:
            return int(
                subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, timeout=5)
            )
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
    try:
        return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, AttributeError):
        return None


def resource_policy(cpu_count: int | None, memory_bytes: int | None) -> dict:
    cpus = max(1, cpu_count or 1)
    memory_mib = memory_bytes // MIB if memory_bytes and memory_bytes > 0 else 0
    # Leave 2 GiB to the OS/build driver, then budget 1.5 GiB per C compiler.
    # Unknown hardware stays conservative. This is a cap, not a peak-memory guarantee.
    memory_jobs = max(1, (memory_mib - 2048) // 1536) if memory_mib else 1
    return {
        "cpuCount": cpus,
        "physicalMemoryMiB": memory_mib or None,
        "compilerJobs": min(cpus, memory_jobs, 8),
        "lowMemory": memory_mib < 6144,
        "policy": "ci-cpu-memory-v1",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-env", action="store_true")
    arguments = parser.parse_args()
    policy = resource_policy(os.cpu_count(), physical_memory())
    if arguments.github_env:
        destination = os.environ.get("GITHUB_ENV")
        if not destination:
            raise SystemExit("GITHUB_ENV is required; local builds keep their existing defaults.")
        with Path(destination).open("a", encoding="utf-8") as stream:
            stream.write(f"MOCHILOG_COMPILER_JOBS={policy['compilerJobs']}\n")
            stream.write(f"MOCHILOG_COMPILER_LOW_MEMORY={int(policy['lowMemory'])}\n")
    Path("Build").mkdir(exist_ok=True)
    Path("Build/compiler-resources.json").write_text(
        json.dumps(policy, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(policy))


if __name__ == "__main__":
    main()
