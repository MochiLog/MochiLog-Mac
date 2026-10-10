"""Packaged entry point for the maintained Apple-device library.

Native Swift/C# code launches this executable without requiring users to
install Python. The two local adapters add bounded direct-IP and battery API
calls; application state, log selection, retention and encryption stay native.
"""

from multiprocessing import freeze_support
import os
import sys
import traceback

freeze_support()

from pymobiledevice3.__main__ import main


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "--mochilog-build-info":
            from CollectorBuildInfo import main as build_info_main
            build_info_main()
        elif len(sys.argv) > 1 and sys.argv[1] == "battery-snapshot":
            from BatterySnapshot import main as snapshot_main
            snapshot_main(sys.argv[2:])
        elif len(sys.argv) > 1 and sys.argv[1] == "direct-rsd":
            from DirectRsd import main as direct_main
            direct_main(sys.argv[2:])
        else:
            main()
    except SystemExit as error:
        if error.code is None:
            code = 0
        elif isinstance(error.code, int):
            code = error.code
        else:
            code = 1
    except BaseException:
        traceback.print_exc()
        code = 1
    else:
        code = 0
    # Native remotepairing can still call into ctypes on a GCD worker while
    # Python finalizes. Exit after flushing CLI output to avoid that race.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)
