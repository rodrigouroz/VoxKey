#!/bin/bash
# Build-time only: copy the checksum-pinned SwiftPM framework for app packaging.
set -euo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 - "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path.cwd()
source = root / '.build/artifacts/voxkey/llama/llama.xcframework/macos-arm64_x86_64/llama.framework'
target = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / '.build/proofreader-runtime'
if not source.is_dir():
    raise SystemExit('Run swift package resolve first to fetch the checksum-pinned llama binary target.')
target.parent.mkdir(parents=True, exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='linked-s1-runtime-', dir=target.parent))
try:
    framework = work / 'llama.framework'
    shutil.copytree(source, framework, symlinks=True)
    binary = framework / 'Versions/A/llama'
    original = binary.read_bytes()
    prefix = b'/Users/runner/work/llama.cpp/llama.cpp/'
    replacement = b'/source/llama.cpp/'
    assert prefix in original, 'Unexpected upstream framework source-path layout'
    # Diagnostic __FILE__ strings only. Fixed-size replacement preserves all code,
    # kernels, offsets and ABI. The original SwiftPM artifact remains untouched.
    normalized = original.replace(prefix, replacement + b'\0' * (len(prefix) - len(replacement)))
    assert b'/Users/' not in normalized and b'/opt/homebrew' not in normalized
    binary.write_bytes(normalized)
    for line in subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True).splitlines():
        if '(compatibility version' in line:
            dependency = line.strip().split(' (compatibility')[0]
            assert dependency.startswith(('@rpath/llama.framework/', '/System/', '/usr/lib/')), dependency
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(framework)], check=True, capture_output=True)
    (work / 'licenses').mkdir()
    shutil.copyfile(root / 'licenses/proofreader-runtime/llama.cpp.txt', work / 'licenses/llama.cpp.txt')
    manifest = {'runtime': 'directly linked llama.framework; no server', 'build': 10809,
                'commit': '5266f24da75dc449bd56cbed7addb9c8e4a6a73e',
                'zip_url': 'https://github.com/ggml-org/llama.cpp/releases/download/b10809/llama-b10809-xcframework.zip',
                'zip_sha256': 'd6813b3b6c73728a19f0bc0d1d7cea04ccdb07f9583c1d930c0b38af2377606d',
                'source_framework_sha256': hashlib.sha256(original).hexdigest(),
                'packaged_framework_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'note': 'Only public CI diagnostic source paths normalized. Re-sign framework before signing the app.'}
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if target.exists():
        old_manifest = json.loads((target / 'manifest.json').read_text())
        assert old_manifest.get('runtime') == manifest['runtime'], 'Destination belongs to a different runtime; preserve it separately.'
        shutil.rmtree(target)
    work.rename(target)
    print(f'Prepared linked framework at {target / "llama.framework"}')
except BaseException:
    shutil.rmtree(work)
    raise
PY
