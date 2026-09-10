#!/bin/zsh
# Run after publishing the release. Produces a signed feed for review and commit on main.
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
release_tag="${1:-}"
[[ "$release_tag" =~ '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] || {
    print -u2 'Usage: prepare-appcast.sh vX.Y.Z'; exit 2
}
# Sparkle compares a monotonic build counter, independent of the SemVer tag.
build_number="$(git show "${release_tag}:VoxKey/Info.plist" | python3 -c '
import plistlib, re, sys
info = plistlib.loads(sys.stdin.buffer.read())
if info["CFBundleShortVersionString"] != sys.argv[1]:
    raise SystemExit("Release tag does not match the tagged app version.")
build = info["CFBundleVersion"]
if not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("Expected a positive internal build number.")
print(build)
' "${release_tag#v}")"
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Start from a clean checkout.'; exit 2; }
repository=rodrigouroz/VoxKey
sparkle="$repo_root/.build/artifacts/sparkle/Sparkle/bin"
account="${VOXKEY_SPARKLE_ACCOUNT:-VoxKey}"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' VoxKey/Info.plist)"
[[ "$("$sparkle/generate_keys" --account "$account" -p)" == "$expected_key" ]] || {
    print -u2 'Sparkle Keychain public key does not match the app.'; exit 2
}
[[ "$(gh release view "$release_tag" --repo "$repository" --json isDraft --jq .isDraft)" == false ]] || {
    print -u2 'Publish the GitHub release before advertising it to installed apps.'; exit 2
}
work_dir="$(mktemp -d "$repo_root/.build/appcast.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
dmg_name="VoxKey-$release_tag-arm64.dmg"
gh release download "$release_tag" --repo "$repository" --dir "$work_dir" \
    --pattern "$dmg_name" --pattern SHA256SUMS
(cd "$work_dir" && shasum -a 256 -c SHA256SUMS)
cmp "$repo_root/dist/$release_tag/$dmg_name" "$work_dir/$dmg_name"
cp docs/appcast.xml "$work_dir/appcast.xml"
# Reject reused/decreasing build numbers even across marketing-version changes.
python3 - "$work_dir/appcast.xml" "$build_number" <<'PY'
import sys, xml.etree.ElementTree as ET
versions = ET.parse(sys.argv[1]).findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
if any(int(version.text) >= int(sys.argv[2]) for version in versions):
    raise SystemExit('Build numbers must increase; this build is already in or older than the feed.')
PY
git show "${release_tag}:docs/release/${release_tag#v}.md" > "$work_dir/${dmg_name%.dmg}.md"
"$sparkle/generate_appcast" --account "$account" --maximum-versions 0 --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$repository/releases/download/$release_tag/" \
    --link https://rodrigouroz.github.io/VoxKey/ --embed-release-notes "$work_dir"
"$sparkle/sign_update" --account "$account" --verify "$work_dir/appcast.xml"
cp "$work_dir/appcast.xml" docs/appcast.xml
print 'Signed docs/appcast.xml is ready. Review it, then commit and push main to deploy GitHub Pages.'
