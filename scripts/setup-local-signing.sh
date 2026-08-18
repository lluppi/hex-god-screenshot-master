#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="Hex God Screenshot Master Local Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "$IDENTITY_NAME"
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
password="$(openssl rand -hex 24)"

cat > "$work_dir/openssl.cnf" <<CONFIG
[req]
prompt = no
distinguished_name = distinguished_name
x509_extensions = extensions

[distinguished_name]
CN = $IDENTITY_NAME
O = leekool Local Development

[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CONFIG

openssl req \
    -new \
    -newkey rsa:2048 \
    -x509 \
    -days 3650 \
    -nodes \
    -config "$work_dir/openssl.cnf" \
    -keyout "$work_dir/private-key.pem" \
    -out "$work_dir/certificate.pem" \
    >/dev/null 2>&1

openssl pkcs12 \
    -export \
    -legacy \
    -inkey "$work_dir/private-key.pem" \
    -in "$work_dir/certificate.pem" \
    -out "$work_dir/identity.p12" \
    -passout "pass:$password"

security import "$work_dir/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$password" \
    -T /usr/bin/codesign \
    >/dev/null
security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$work_dir/certificate.pem"

echo "$IDENTITY_NAME"
