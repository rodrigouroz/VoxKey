#!/bin/zsh
# Public certificate metadata only. Rotate this pin deliberately when renewing it.
voxkey_signing_identity() {
    local certificate_sha1=0E2CEF88A0CD90DD1E3F047D711339DD9FBD6CC2
    local certificate_name='Developer ID Application: Rodrigo Uroz (6QMEN99W4B)'
    local requested="${VOXKEY_SIGNING_IDENTITY:-$certificate_sha1}"
    if [[ "$requested" == "-" && "${1:-}" == "preview" ]]; then
        print -r -- '-'
        return
    fi
    if [[ "$requested" != "$certificate_sha1" && "$requested" != "$certificate_name" ]]; then
        print -u2 'VoxKey requires its pinned Developer ID certificate. Ad-hoc signing is allowed only for the separate packaging preview.'
        return 1
    fi
    local identities
    identities="$(security find-identity -v -p codesigning)" || return 1
    if [[ "$identities" != *"$certificate_sha1"* ]]; then
        print -u2 "Missing signing identity: $certificate_name ($certificate_sha1). Install this certificate and its private key; refusing to change VoxKey's privacy identity."
        return 1
    fi
    print -r -- "$certificate_sha1"
}

voxkey_verify_signature() {
    if [[ "$2" == "-" ]]; then
        codesign --verify --deep --strict "$1"
    else
        codesign --verify --deep --strict -R "=anchor apple generic and certificate leaf = H\"$2\"" "$1"
    fi
}
