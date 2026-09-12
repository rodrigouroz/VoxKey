#!/usr/bin/env python3
"""Exercise the actual compiler and packaging rejection boundaries."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix="voxkey-diagnostic-gate-") as cache:
        source = "Sources/VoxKeyApp/TranscriptionDiagnostics.swift"
        for flags in [[], ["DEBUG"], ["VOXKEY_RELEASE"], ["DEBUG", "VOXKEY_RELEASE"]]:
            result = run(["swiftc", "-typecheck", "-module-cache-path", cache, source]
                         + [argument for flag in flags for argument in ["-D", flag]])
            assert result.returncode == 0, result.stderr
        for flags in [["VOXKEY_LOCAL_DIAGNOSTICS"],
                      ["VOXKEY_LOCAL_DIAGNOSTICS", "VOXKEY_RELEASE"],
                      ["DEBUG", "VOXKEY_LOCAL_DIAGNOSTICS", "VOXKEY_RELEASE"]]:
            result = run(["swiftc", "-typecheck", "-module-cache-path", cache, source]
                         + [argument for flag in flags for argument in ["-D", flag]])
            assert result.returncode != 0 and "Local diagnostics require Debug" in result.stderr, result.stderr

    environment = dict(os.environ, VOXKEY_LOCAL_DIAGNOSTICS="1")
    for configuration in ["debug", "release"]:
        for kind in ["app", "candidate", "preview", "distribution"]:
            result = run(["zsh", "scripts/build-app.sh", configuration, kind], env=environment)
            assert result.returncode == 2 and "never allow them" in result.stderr, result.stderr
    result = run(["zsh", "scripts/build-app.sh", "release", "development"], env=environment)
    assert result.returncode == 2 and "require Debug" in result.stderr, result.stderr
    print("Diagnostic boundary passed: 7 compiler cases and 9 rejected packaging configurations.")


if __name__ == "__main__":
    main()
