#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="$repo_root/.build/VoxKeyValidation.app"
source "$repo_root/scripts/signing-identity.sh"
signing_identity="$(voxkey_signing_identity)"
cd "$repo_root"
swift build --product VoxKey -Xswiftc -DVOXKEY_INTERNAL_DIAGNOSTICS
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/VoxKey "$app/Contents/MacOS/VoxKey"
cp VoxKey/Info.plist "$app/Contents/Info.plist"
for bundle in .build/debug/*.bundle(N); do
    ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
codesign --force --deep --sign "$signing_identity" --timestamp --entitlements VoxKey/Resources/VoxKey.entitlements "$app"
voxkey_verify_signature "$app" "$signing_identity"
print "$app"
