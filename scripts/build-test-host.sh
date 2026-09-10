#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_root="$repo_root/.build/debug"
app="$repo_root/.build/VoxKeyTestHost.app"
source "$repo_root/scripts/signing-identity.sh"
signing_identity="$(voxkey_signing_identity)"

cd "$repo_root"
swift build --arch arm64 --product VoxKeyTestHost

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$build_root/VoxKeyTestHost" "$app/Contents/MacOS/VoxKeyTestHost"
cp "$repo_root/TestHost/Info.plist" "$app/Contents/Info.plist"

codesign --force --sign "$signing_identity" --timestamp "$app"
voxkey_verify_signature "$app" "$signing_identity"
echo "$app"
