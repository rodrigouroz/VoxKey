#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
configuration="${1:-release}"
[[ "$configuration" == "debug" || "$configuration" == "release" ]] || { print -u2 "Expected debug or release"; exit 2; }
build_root="$repo_root/.build/$configuration"
build_kind="${2:-app}"
case "$build_kind" in
    app) app="$repo_root/.build/VoxKey.app" ;;
    candidate) app="$repo_root/.build/VoxKeyCandidate.app" ;;
    development) app="$repo_root/.build/VoxKeyDevelopment.app" ;;
    preview) app="$repo_root/.build/packaging-preview/VoxKey Packaging Preview.app" ;;
    distribution) app="$repo_root/.build/distribution/VoxKey.app" ;;
    *) print -u2 "Usage: build-app.sh [debug|release] [app|candidate|development|preview|distribution]"; exit 2 ;;
esac
local_diagnostics="${VOXKEY_LOCAL_DIAGNOSTICS:-0}"
[[ "$local_diagnostics" == 0 || "$local_diagnostics" == 1 ]] || { print -u2 'VOXKEY_LOCAL_DIAGNOSTICS must be 0 or 1.'; exit 2; }
if [[ "$build_kind" == development && "$configuration" != debug ]]; then
    print -u2 'Development bundles require Debug configuration.'; exit 2
fi
if [[ "$local_diagnostics" == 1 && ( "$configuration" != debug || "$build_kind" != development ) ]]; then
    print -u2 'Diagnostics require an explicit local Debug development build; release candidates and public bundles never allow them.'; exit 2
fi
if [[ -n "${VOXKEY_GRAMMAR_ASSETS:-}" ]]; then
    print -u2 "Grammar weights are now downloaded by VoxKey. Remove VOXKEY_GRAMMAR_ASSETS; no model is bundled."
    exit 2
fi
source "$repo_root/scripts/signing-identity.sh"
signing_identity="$(voxkey_signing_identity "$build_kind")"
if [[ "$build_kind" == "distribution" && "$configuration" != "release" ]]; then
    print -u2 'Distribution requires release configuration.'
    exit 2
fi

cd "$repo_root"
diagnostic_flags=(-Xswiftc -DVOXKEY_RELEASE)
if [[ "$build_kind" == development ]]; then
    diagnostic_flags=()
    if [[ "$local_diagnostics" == 1 ]]; then
        diagnostic_flags=(-Xswiftc -DVOXKEY_LOCAL_DIAGNOSTICS)
    fi
fi
swift build -c "$configuration" --arch arm64 --product VoxKey --force-resolved-versions \
    "${diagnostic_flags[@]}" \
    -debug-info-format none -Xswiftc -DVOXKEY_PACKAGED \
    -Xswiftc -file-prefix-map -Xswiftc "$repo_root=." \
    -Xcc "-ffile-prefix-map=$repo_root=."
"$repo_root/scripts/prepare-proofreader-runtime.sh"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_root/VoxKey" "$app/Contents/MacOS/VoxKey"
# Remove linker debug-map paths before signing the executable.
xcrun strip -S "$app/Contents/MacOS/VoxKey"
cp "$repo_root/VoxKey/Info.plist" "$app/Contents/Info.plist"

build_id="$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD)"
/usr/libexec/PlistBuddy -c "Add :VoxKeyBuildID string $build_id" "$app/Contents/Info.plist"
if [[ "$build_kind" == "preview" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.rodrigouroz.VoxKey.PackagingPreview' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName VoxKey Packaging Preview' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string VoxKey Packaging Preview' "$app/Contents/Info.plist"
fi
if [[ "$build_kind" == "distribution" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :VoxKeyReleaseBuild bool true' "$app/Contents/Info.plist"
fi

mkdir -p "$app/Contents/Resources/Licenses"
cp "$repo_root/LICENSE" "$app/Contents/Resources/Licenses/VoxKey.txt"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/Licenses/"
ditto "$repo_root/licenses/grammar" "$app/Contents/Resources/Licenses/Grammar"
ditto "$repo_root/licenses/improvement" "$app/Contents/Resources/Licenses/Improvement"
ditto "$repo_root/.build/proofreader-runtime/licenses" "$app/Contents/Resources/Licenses/ProofreaderRuntime"
cp "$repo_root/.build/proofreader-runtime/manifest.json" "$app/Contents/Resources/Licenses/ProofreaderRuntime/manifest.json"
for dependency in argmax-oss-swift ZIPFoundation swift-argument-parser; do
    license="$repo_root/.build/checkouts/$dependency/LICENSE"
    [[ -f "$license" ]] || license="$license.txt"
    cp "$license" "$app/Contents/Resources/Licenses/$dependency.txt"
done
cp "$repo_root/.build/checkouts/argmax-oss-swift/NOTICES" "$app/Contents/Resources/Licenses/ArgmaxOSS-NOTICES.txt"
sparkle_root="$repo_root/.build/artifacts/sparkle/Sparkle"
cp "$sparkle_root/LICENSE" "$app/Contents/Resources/Licenses/Sparkle.txt"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
ditto "$repo_root/.build/proofreader-runtime/llama.framework" "$app/Contents/Frameworks/llama.framework"

xcrun actool \
    --compile "$app/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$build_root/VoxKeyAssetInfo.plist" \
    "$repo_root/VoxKey/Resources/Assets.xcassets"

# Explicit inputs prevent stale bundles from an unrelated build entering the app.
for bundle_name in VoxKey_VoxKeyApp.bundle ZIPFoundation_ZIPFoundation.bundle; do
    cp -R "$build_root/$bundle_name" "$app/Contents/Resources/"
done

if [[ "$signing_identity" == "-" ]]; then
    print -u2 "warning: using an ad-hoc signature; macOS privacy grants can reset whenever this app is rebuilt"
fi

framework="$app/Contents/Frameworks/Sparkle.framework"
signing_options=(--force --sign "$signing_identity" --options runtime)
if [[ "$signing_identity" != "-" ]]; then
    signing_options+=(--timestamp)
else
    signing_options+=(--timestamp=none)
fi
# Sign nested executables inside out, preserving Sparkle's helper entitlements.
for code in "$framework/Versions/B/XPCServices/Downloader.xpc" \
            "$framework/Versions/B/XPCServices/Installer.xpc" \
            "$framework/Versions/B/Autoupdate" \
            "$framework/Versions/B/Updater.app" "$framework"; do
    codesign "${signing_options[@]}" --preserve-metadata=entitlements "$code"
done
codesign "${signing_options[@]}" "$app/Contents/Frameworks/llama.framework"

if [[ "$signing_identity" != "-" ]]; then
    codesign --force --sign "$signing_identity" --options runtime --timestamp \
        --entitlements "$repo_root/VoxKey/Resources/VoxKey.Release.entitlements" "$app"
else
    codesign --force --deep --sign "$signing_identity" \
        --entitlements "$repo_root/VoxKey/Resources/VoxKey.entitlements" "$app"
fi

voxkey_verify_signature "$app" "$signing_identity"
python3 "$repo_root/scripts/verify-artifact-privacy.py" "$app"
if [[ "$local_diagnostics" != 1 ]]; then
    python3 "$repo_root/scripts/verify-no-diagnostics.py" "$app"
fi
echo "$app"
