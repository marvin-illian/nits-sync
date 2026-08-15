#!/bin/zsh

set -euo pipefail

app_path="${1:?Pass the path of the .app bundle to sign}"

if [[ ! -d "$app_path" ]]; then
    print -u2 "App bundle not found: $app_path"
    exit 1
fi

identity="$({ security find-identity -v -p codesigning || true; } \
    | awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"

if [[ -z "$identity" ]]; then
    print -u2 "No valid code-signing identity was found in the keychain."
    print -u2 "Build the local ad-hoc-signed app with: make app"
    exit 1
fi

print "Signing $app_path with the first available identity: $identity"
codesign \
    --force \
    --sign "$identity" \
    --options runtime \
    --timestamp=none \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
