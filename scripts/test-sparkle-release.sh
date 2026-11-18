#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PYTEST'
from pathlib import Path
import json
import subprocess
import tempfile

root = Path.cwd()
with tempfile.TemporaryDirectory(prefix="mochilog-sparkle-verification-") as temporary:
    folder = Path(temporary)
    subprocess.run(["swift", str(root / "Tests/SparkleReleaseFixture.swift"), temporary],
                   check=True, capture_output=True, timeout=60)
    cases = [
        ("valid.xml", "archive.dmg", "1.0.3", "41", None),
        ("valid.xml", "archive.dmg", "1.0.2", "40", "Feed version differs"),
        ("old-first.xml", "archive.dmg", "1.0.3", "41", "Feed version differs"),
        ("wrong-url.xml", "archive.dmg", "1.0.3", "41", "Invalid archive enclosure"),
        ("valid.xml", "tampered.dmg", "1.0.3", "41", "Archive signature failed"),
        ("tampered.xml", "archive.dmg", "1.0.3", "41", "Feed signature failed"),
    ]
    for feed, archive, version, build, error in cases:
        result = subprocess.run(
            ["swift", str(root / "scripts/verify-sparkle-release.swift"),
             str(folder / feed), str(folder / archive), version, build],
            cwd=folder, capture_output=True, text=True, timeout=60)
        if error is None:
            assert result.returncode == 0, result.stderr
            proof = json.loads(result.stdout)
            assert proof["version"] == version and proof["build"] == build
            assert proof["feedSignatureVerified"] and proof["archiveSignatureVerified"]
        else:
            assert result.returncode != 0 and error in result.stderr, (error, result.stderr)
print("PASS: signed multi-version feed, latest selection, URL and archive/feed tampering (6 cases)")
PYTEST
