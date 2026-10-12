#!/bin/bash
set -euo pipefail
NAME="LidShot Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists"
    exit 0
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout pass:lidshot
security import "$WORK/id.p12" -k "$KEYCHAIN" -P lidshot -T /usr/bin/codesign >/dev/null
echo "Imported \"$NAME\""
