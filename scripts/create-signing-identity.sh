#!/bin/bash
# Creates a local, self-signed code-signing certificate "SyncForge Local Signing" in your login
# keychain. Signing every build with the same identity lets macOS remember the System Audio
# Recording and Microphone permissions across rebuilds. The certificate never leaves this Mac and
# is only meaningful to it. Remove it any time with Keychain Access.
set -euo pipefail
NAME="SyncForge Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/cfg" -extensions ext >/dev/null 2>&1
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:"$PASS" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:"$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". scripts/build.sh will now use it automatically."
echo "(macOS may ask once to allow codesign to use the key — choose \"Always Allow\".)"
