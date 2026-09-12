#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
VOXKEY_LOCAL_DIAGNOSTICS=1 ./scripts/build-app.sh debug development
