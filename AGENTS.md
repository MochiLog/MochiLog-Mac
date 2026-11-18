# Runtime diagnostics

Before a PC release, check the latest stable pymobiledevice3 on official PyPI. When updating, refresh the pin in both PC repositories, review API and CLI changes, and run the Python bridge, native protocol and isolated compiled-collector checks (including the direct-provider contract and actual command argument shapes). Record the checked version and results in developer documentation. Users must not need an external Python installation.

Use the app's NativeDiagnostics/current.json or its support export when investigating runtime behavior. Read [docs/NATIVE_DIAGNOSTICS.md](docs/NATIVE_DIAGNOSTICS.md) first. Copy existing diagnostic files and parse them locally; do not recreate an unbounded report in a shell.

Helper invocations use GuardedProcess with a deadline, bounded output, process-group ownership and a resident-memory guard. Never restore blocking EOF reads, unbounded temporary output files, or terminate-without-wait cleanup. Temporary investigation processes need the same bounded lifetime and cleanup when canceled.

Never commit raw snapshots, logs, pairing data or private keys. Keep developer notes in docs/ and README focused on user setup.
