#!/bin/bash
# One-time: create a self-signed code-signing certificate named "dikta-dev" so
# TCC permission grants persist across rebuilds (ad-hoc signatures change cdhash
# every build, which resets Accessibility/Input Monitoring grants).
set -euo pipefail

NAME="dikta-dev"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "certificate '$NAME' already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf"
# -legacy: OpenSSL 3 defaults to PBES2/AES which macOS `security import` rejects
openssl pkcs12 -export -legacy -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:dikta

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P dikta \
    -T /usr/bin/codesign

# Trust it for code signing (will prompt for your login password once).
security add-trusted-cert -d -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" || {
    echo "note: add-trusted-cert needs admin; you can also trust the cert via Keychain Access."
}

echo "created signing identity '$NAME'"
