#!/usr/bin/env python3
"""Bundle license notices for the Python environment used by the collector."""

from importlib import metadata
from pathlib import Path
import sys


def license_files(distribution):
    for entry in distribution.files or []:
        path = Path(str(entry))
        name = path.name.lower()
        if name in {"license", "license.txt", "license.md", "copying", "copying.txt", "notice", "notice.txt"}:
            actual = Path(distribution.locate_file(entry))
            if actual.is_file():
                yield actual


def main(output):
    sections = ["Python dependencies bundled with MochiLog Mac\n"]
    for distribution in sorted(metadata.distributions(), key=lambda item: (item.metadata.get("Name") or "").lower()):
        name = distribution.metadata.get("Name") or "Unknown package"
        version = distribution.version
        sections.append(f"\n{'=' * 72}\n{name} {version}\n{'=' * 72}\n")
        expression = distribution.metadata.get("License-Expression") or distribution.metadata.get("License")
        if expression:
            sections.append(f"License metadata: {expression}\n")
        homepage = distribution.metadata.get("Home-page") or distribution.metadata.get("Project-URL")
        if homepage:
            sections.append(f"Project: {homepage}\n")
        seen = set()
        for file in license_files(distribution):
            content = file.read_text(encoding="utf-8", errors="replace")
            if content in seen:
                continue
            seen.add(content)
            sections.append(f"\n--- {file.name} ---\n{content.rstrip()}\n")
        if not seen:
            sections.append("No license text was included in this package metadata. See the project URL above.\n")
    Path(output).write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1])
