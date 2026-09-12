#!/usr/bin/env python3
"""Reject VoxKey diagnostic messages and inspection entrypoints in public binaries.

This checks the emitted executable, including builds with accidentally supplied
compiler flags. It does not claim to remove logging inside macOS or dependencies.
"""

import argparse
from pathlib import Path
import re
import sys


def diagnostic_markers():
    source_root = Path(__file__).resolve().parent.parent / "Sources" / "VoxKeyApp"
    messages = re.compile(
        r'(?:\blogger\.\w+|\bLogger\([^\n]+?\)\.\w+)\(\s*"((?:\\.|[^"\\])*)"'
    )
    markers = {b"--inspect-destination", b"--verify-delivery",
               b"VoxKeyTemporaryTranscriptionTraceEnabled",
               b"Record temporary transcription traces", b"Diagnostics/Transcription"}
    markers.update({b"TranscriptionDiagnostics", b"TranscriptionTrace",
                    b"TranscriptionDiagnosticsCard"})
    for path in source_root.glob("*.swift"):
        for literal in messages.findall(path.read_text()):
            prefix = literal.split(r"\(", 1)[0]
            if len(prefix) < 8:
                raise ValueError(f"Diagnostic message needs a unique static prefix: {path.name}")
            markers.add(prefix.encode())
    return markers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    binary = args.app / "Contents" / "MacOS" / "VoxKey"
    if not binary.is_file():
        parser.error("Expected a built VoxKey app bundle")
    try:
        markers = diagnostic_markers()
    except ValueError as error:
        parser.error(str(error))
    data = binary.read_bytes()
    found = [marker for marker in markers if marker in data]
    if found:
        print(f"Public-build check failed: {len(found)} VoxKey diagnostic markers remain.", file=sys.stderr)
        return 1
    print(f"Public-build check passed: {len(markers)} VoxKey diagnostic markers absent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
