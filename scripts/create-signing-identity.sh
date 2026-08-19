#!/bin/bash
# Creates a stable self-signed code-signing identity in the login keychain so that
# the Accessibility permission granted to the app survives rebuilds. Run once.
# build.sh picks the identity up automatically by name.
set -euo pipefail

IDENTITY="IMEModeSwitcher Local Signing"

if security find-identity -v 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity already exists: $IDENTITY"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE"

# -legacy: Apple's Security framework can't read OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:temp1234 -name "$IDENTITY"

# -A lets codesign use the key without a keychain prompt on every build.
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P temp1234 -A -T /usr/bin/codesign

echo "Created identity: $IDENTITY"
echo "Now run ./scripts/build.sh — it will sign with this identity."
