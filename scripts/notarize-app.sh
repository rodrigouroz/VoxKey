#!/bin/zsh
# Use the account already signed into Xcode; private credentials stay in Keychain.
set -euo pipefail
app="${1:A}"
output="${2:A}"
team="${VOXKEY_TEAM_ID:?Set VOXKEY_TEAM_ID to the Developer ID team.}"
[[ -d "$app" && ! -e "$output" ]] || { print -u2 'Expected an app and a new output directory.'; exit 2; }
mkdir -p "$output/VoxKey.xcarchive/Products/Applications"
ditto "$app" "$output/VoxKey.xcarchive/Products/Applications/VoxKey.app"
python3 - "$app" "$output" "$team" <<'PY'
import datetime, pathlib, plistlib, sys
app, output, team = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
archive = {
    'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
    'Name': 'VoxKey', 'SchemeName': 'VoxKey',
    'ApplicationProperties': {
        'ApplicationPath': 'Applications/VoxKey.app', 'CFBundleIdentifier': info['CFBundleIdentifier'],
        'CFBundleShortVersionString': info['CFBundleShortVersionString'],
        'CFBundleVersion': info['CFBundleVersion'], 'Team': team,
    },
}
(output / 'VoxKey.xcarchive/Info.plist').write_bytes(plistlib.dumps(archive))
(output / 'ExportOptions.plist').write_bytes(plistlib.dumps({
    'method': 'developer-id', 'destination': 'upload', 'signingStyle': 'manual',
    'signingCertificate': 'Developer ID Application', 'teamID': team,
    'manageAppVersionAndBuildNumber': False,
}))
PY
xcodebuild -exportArchive -archivePath "$output/VoxKey.xcarchive" \
    -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output/upload"
# Upload success is not notarization success. Retry only Apple's explicit pending state.
for attempt in {1..40}; do
    if xcodebuild -exportNotarizedApp -archivePath "$output/VoxKey.xcarchive" \
        -exportPath "$output/notarized" > "$output/export.log" 2>&1; then
        cat "$output/export.log"
        break
    fi
    if ! /usr/bin/grep -q 'is processing and not ready for distribution' "$output/export.log" || (( attempt == 40 )); then
        cat "$output/export.log" >&2
        print -u2 "No accepted export. Archive and result retained in $output; do not publish."
        exit 1
    fi
    print "Apple is processing the app; checking again in 15 seconds ($attempt/40)."
    sleep 15
done
xcrun stapler validate "$output/notarized/VoxKey.app"
codesign --verify --deep --strict "$output/notarized/VoxKey.app"
spctl --assess --type execute --verbose=2 "$output/notarized/VoxKey.app"
