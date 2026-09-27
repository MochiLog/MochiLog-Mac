#!/usr/bin/env python3
"""Bundle license notices for the Python environment used by the collector."""

from importlib import metadata
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_LICENSES = {
    "loguru": (ROOT / "Resources/PythonLicenses/loguru-LICENSE.txt",
               "https://github.com/Delgan/loguru/blob/master/LICENSE"),
}


def license_files(distribution):
    for entry in distribution.files or []:
        path = Path(str(entry))
        name = path.name.lower()
        if name.startswith(("license", "licence", "copying", "notice")):
            actual = Path(distribution.locate_file(entry))
            if actual.is_file() and actual.stat().st_size <= 500_000:
                yield actual


def main(output):
    sections = ["Python dependencies bundled with MochiLog Mac\n"]
    individual = Path(output).parent / "PythonLicenses"
    individual.mkdir(parents=True, exist_ok=True)
    for distribution in sorted(metadata.distributions(), key=lambda item: (item.metadata.get("Name") or "").lower()):
        name = distribution.metadata.get("Name") or "Unknown package"
        version = distribution.version
        entry = [f"{name} {version}\n{'=' * 72}\n"]
        expression = distribution.metadata.get("License-Expression") or distribution.metadata.get("License")
        if expression:
            entry.append(f"License metadata: {expression}\n")
        for classifier in distribution.metadata.get_all("Classifier", []):
            if classifier.startswith("License ::"):
                entry.append(f"License classifier: {classifier}\n")
        homepage = distribution.metadata.get("Home-page")
        if homepage:
            entry.append(f"Project: {homepage}\n")
        for project_url in distribution.metadata.get_all("Project-URL", []):
            entry.append(f"Project: {project_url}\n")
        seen = set()
        for file in license_files(distribution):
            content = file.read_text(encoding="utf-8", errors="replace")
            if content in seen:
                continue
            seen.add(content)
            entry.append(f"\n--- {file.name} ---\n{content.rstrip()}\n")
        if not seen:
            upstream = UPSTREAM_LICENSES.get(name.lower())
            if upstream:
                source, url = upstream
                entry.append(f"\n--- LICENSE (upstream: {url}) ---\n"
                             f"{source.read_text(encoding='utf-8').rstrip()}\n")
            else:
                entry.append("No license text was included in this package metadata. See the project URL above.\n")
        filename = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{name}-{version}") + ".txt"
        (individual / filename).write_text("".join(entry), encoding="utf-8")
        sections.append(f"\n{'=' * 72}\n{''.join(entry)}")
    Path(output).write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1])
