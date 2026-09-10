#!/bin/zsh
# Preview: package locally without claiming distribution readiness.
# Release: require a clean tagged revision, Developer ID, and successful notarization.
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
release_tag="${1:-}"
mode="${2:-notarized}"
[[ "$release_tag" =~ '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] || {
    print -u2 "Usage: package-release.sh vX.Y.Z [notarized|preview]"; exit 2
}
version="${release_tag#v}"
[[ "$mode" == "notarized" || "$mode" == "preview" ]] || { print -u2 "Unknown mode: $mode"; exit 2; }
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' VoxKey/Info.plist)"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' VoxKey/Info.plist)"
[[ "$version" == "$plist_version" && "$plist_build" =~ '^[1-9][0-9]*$' ]] || {
    print -u2 "Tag must match Info.plist version ($plist_version), with a positive internal build number ($plist_build)."; exit 2
}
if [[ "$mode" == "notarized" ]]; then
    [[ -n "${VOXKEY_PRIVACY_DENYLIST:-}" && -s "$VOXKEY_PRIVACY_DENYLIST" ]] || {
        print -u2 'Set VOXKEY_PRIVACY_DENYLIST to a nonempty private file of forbidden identifiers.'; exit 2
    }
    [[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit all release inputs before packaging."; exit 2; }
    [[ "$(git rev-parse "$release_tag^{commit}")" == "$(git rev-parse HEAD)" ]] || {
        print -u2 "Check out the release tag before packaging."; exit 2
    }
    [[ -n "${VOXKEY_NOTARY_PROFILE:-}" || -n "${VOXKEY_TEAM_ID:-}" ]] || {
        print -u2 "Set VOXKEY_TEAM_ID for your Xcode account, or VOXKEY_NOTARY_PROFILE for notarytool."; exit 2
    }
fi
suffix=""
[[ "$mode" != "preview" ]] || suffix="-LOCAL-PREVIEW"
output="$repo_root/dist/$release_tag$suffix"
[[ ! -e "$output" ]] || { print -u2 "Output already exists: $output. Move it aside before retrying."; exit 2; }
mkdir -p "$output" "$repo_root/.build"
work_dir="$(mktemp -d "$repo_root/.build/release-package.XXXXXX")"
mounted=0
cleanup() {
    if (( mounted )); then
        hdiutil detach "$work_dir/mounted" >/dev/null || return
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
if [[ "$mode" == "notarized" ]]; then
    ./scripts/build-app.sh release distribution
    app="$repo_root/.build/distribution/VoxKey.app"
    if [[ -n "${VOXKEY_NOTARY_PROFILE:-}" ]]; then
        ditto -c -k --keepParent "$app" "$work_dir/VoxKey.zip"
        xcrun notarytool submit "$work_dir/VoxKey.zip" --keychain-profile "$VOXKEY_NOTARY_PROFILE" --wait
        xcrun stapler staple "$app"
    else
        # Preserve the archive outside the temporary directory if Apple is still processing.
        ./scripts/notarize-app.sh "$app" "$repo_root/.build/notarization/$release_tag"
        app="$repo_root/.build/notarization/$release_tag/notarized/VoxKey.app"
    fi
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
else
    ./scripts/build-app.sh release preview
    app="$repo_root/.build/packaging-preview/VoxKey Packaging Preview.app"
fi
mkdir -p "$work_dir/image"
ditto "$app" "$work_dir/image/${app:t}"
ln -s /Applications "$work_dir/image/Applications"
cp LICENSE "$work_dir/image/LICENSE.txt"
if [[ "$mode" == "preview" ]]; then
    print 'LOCAL PACKAGING PREVIEW ONLY. Not notarized; do not distribute as a release.' > "$work_dir/image/LOCAL-PREVIEW.txt"
fi
dmg_name="VoxKey-$release_tag-arm64$suffix.dmg"
hdiutil create -volname "VoxKey $version" -srcfolder "$work_dir/image" \
    -fs APFS -format ULFO -ov "$output/$dmg_name"
if [[ "$mode" == "notarized" && -n "${VOXKEY_NOTARY_PROFILE:-}" ]]; then
    source "$repo_root/scripts/signing-identity.sh"
    codesign --sign "$(voxkey_signing_identity)" --timestamp "$output/$dmg_name"
    xcrun notarytool submit "$output/$dmg_name" --keychain-profile "$VOXKEY_NOTARY_PROFILE" --wait
    xcrun stapler staple "$output/$dmg_name"
    xcrun stapler validate "$output/$dmg_name"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$output/$dmg_name"
fi
hdiutil verify "$output/$dmg_name"
codesign --verify --deep --strict "$app"
{
    print "Release: $release_tag"
    print "Build: $plist_build"
    print "Mode: $mode"
    if [[ "$mode" == "notarized" ]]; then
        print 'App: Developer ID signed, notarized, and stapled'
        if [[ -n "${VOXKEY_NOTARY_PROFILE:-}" ]]; then
            print 'DMG: Developer ID signed, notarized, and stapled'
        else
            print 'DMG: unsigned container; the enclosed app is signed, notarized, and stapled'
        fi
    fi
    print "Commit: $(git rev-parse HEAD)"
    print "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$output/build-info.txt"
cd "$output"
shasum -a 256 "$dmg_name" > SHA256SUMS
# Verify the actual compressed artifact after all signing and notarization steps.
mkdir "$work_dir/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$work_dir/mounted" "$output/$dmg_name" >/dev/null
mounted=1
python3 "$repo_root/scripts/verify-artifact-privacy.py" \
    "$work_dir/mounted" "$output/build-info.txt" "$output/SHA256SUMS"
hdiutil detach "$work_dir/mounted" >/dev/null
mounted=0
print "Created $output/$dmg_name"
