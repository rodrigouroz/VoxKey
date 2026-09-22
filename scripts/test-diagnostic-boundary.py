#!/usr/bin/env python3
"""Exercise the actual compiler and packaging rejection boundaries."""

import os
from pathlib import Path
import subprocess
import sys
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
        result = run(["swiftc", "-typecheck", "-module-cache-path", cache,
                      "Sources/VoxKeyApp/PerformanceRecording.swift", "-D", "VOXKEY_PERFORMANCE", "-D", "VOXKEY_RELEASE"])
        assert result.returncode != 0 and "restricted to local performance builds" in result.stderr, result.stderr

    environment = dict(os.environ, VOXKEY_LOCAL_DIAGNOSTICS="1")
    for configuration in ["debug", "release"]:
        for kind in ["app", "candidate", "preview", "distribution"]:
            result = run(["zsh", "scripts/build-app.sh", configuration, kind], env=environment)
            assert result.returncode == 2 and "never allow them" in result.stderr, result.stderr
    result = run(["zsh", "scripts/build-app.sh", "release", "development"], env=environment)
    assert result.returncode == 2 and "require Debug" in result.stderr, result.stderr
    result = run(["zsh", "scripts/build-app.sh", "debug", "performance"])
    assert result.returncode == 2 and "require optimized Release" in result.stderr, result.stderr
    result = run(["zsh", "scripts/build-app.sh", "release", "performance"], env=environment)
    assert result.returncode == 2 and "never allow them" in result.stderr, result.stderr
    # Exercise the public artifact gate, including the narrow local-performance
    # exception. That exception must never admit transcription diagnostics.
    with tempfile.TemporaryDirectory(prefix="voxkey-diagnostic-artifact-") as root:
        app = Path(root) / "VoxKey.app"
        binary = app / "Contents" / "MacOS" / "VoxKey"
        binary.parent.mkdir(parents=True)
        scanner = [sys.executable, "scripts/verify-no-diagnostics.py", str(app)]
        for marker in [b"PerformanceRecording", b"DestinationDiagnostics", b"Diagnostics/Performance"]:
            binary.write_bytes(b"\x00" + marker + b"\x00")
            assert run(scanner).returncode == 1
            assert run(scanner + ["--allow-performance"]).returncode == 0
        binary.write_bytes(b"\x00TranscriptionDiagnostics\x00")
        assert run(scanner).returncode == 1
        assert run(scanner + ["--allow-performance"]).returncode == 1
        binary.write_bytes(b"Public application content")
        assert run(scanner).returncode == 0
    print("Diagnostic boundary passed: 8 compiler cases, 11 rejected packaging configurations, and 9 artifact cases.")


if __name__ == "__main__":
    main()
