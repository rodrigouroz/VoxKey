#!/usr/bin/env python3
"""Reject private paths and maintainer-supplied terms in publishable artifacts.

Pass an app, a mounted disk image, or release metadata. Compressed containers
must be unpacked first. VOXKEY_PRIVACY_DENYLIST optionally names a private UTF-8
file with one literal term per line; its contents are never printed.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


def patterns():
    rules = [
        ("home directory", re.compile(rb"/Users/|/home/|[A-Z]:\\Users\\", re.I)),
        ("private temporary directory", re.compile(rb"/private/(?:tmp|var/folders)/", re.I)),
    ]
    literals = {str(Path.home()), str(Path(__file__).resolve().parent.parent)}
    for key in ("ComputerName", "LocalHostName", "HostName"):
        result = subprocess.run(["scutil", "--get", key], capture_output=True, text=True)
        if result.returncode == 0 and len(result.stdout.strip()) > 3:
            literals.add(result.stdout.strip())
    denylist = os.environ.get("VOXKEY_PRIVACY_DENYLIST")
    if denylist:
        literals.update(line.strip() for line in Path(denylist).read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith("#"))
    for literal in literals:
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            rules.append(("private identifier", re.compile(re.escape(literal.encode(encoding)), re.I)))
    return rules


def violations(data, rules):
    # Check ordinary binary strings and UTF-16 strings without printing matches.
    return {name for name, pattern in rules
            if pattern.search(data) or pattern.search(data.replace(b"\0", b""))}


def scan(root, rules):
    root = root.absolute()
    paths = [root, *root.rglob("*")] if root.is_dir() else [root]
    findings = []
    count = 0
    for path in paths:
        label = str(path.relative_to(root)) if path != root else root.name
        data = os.fsencode(label)
        if path.is_symlink():
            target = os.readlink(path)
            data += os.fsencode(target)
            # The install shortcut is the sole permitted external link.
            if not path.resolve().is_relative_to(root.resolve()) and target != "/Applications":
                findings.append((label, "external symlink"))
        elif path.is_file():
            data += path.read_bytes()
            count += 1
        names = subprocess.check_output(["xattr", "-s", str(path)], text=True).splitlines()
        for name in names:
            value = subprocess.check_output(["xattr", "-s", "-p", "-x", name, str(path)], text=True)
            data += os.fsencode(name) + bytes.fromhex(value)
        findings.extend((label, reason) for reason in violations(data, rules))
    return count, findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", type=Path)
    args = parser.parse_args()
    rules = patterns()
    total = 0
    failed = False
    for root in args.artifacts:
        if not root.exists():
            parser.error("Artifact does not exist")
        if root.suffix.lower() in {".dmg", ".zip", ".gz"}:
            parser.error("Mount or unpack compressed artifacts before scanning")
        count, findings = scan(root, rules)
        total += count
        for label, reason in findings:
            # Paths are artifact-relative; matched private content stays private.
            print(f"Privacy check failed: {label}: {reason}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"Artifact privacy check passed ({total} files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
