#!/bin/zsh
# Create a self-signed "Koe Dev Signing" certificate in the login keychain for signing Koe Dev.app.
#
# Why: macOS ties permissions (microphone, system audio) to the app's signature.
# Without a certificate every rebuild is a "new" app, and the permissions reset.
# With a certificate the signature stays the same after a rebuild, and the permissions are kept.
#
# The certificate is only good for signing your own apps on this Mac; there's no need to "trust" it
# in Keychain Access. To remove it: Keychain Access → My Certificates → Koe Dev Signing.
set -e
NAME="Koe Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The \"$NAME\" certificate is already in the keychain — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
# the system openssl (LibreSSL): the keychain accepts its .p12 without extra flags
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
# -T: codesign is allowed to sign with this key
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Done: the \"$NAME\" certificate is in the keychain."
echo "On the first build macOS may ask for your Mac password to let codesign use the key — click \"Always Allow\"."
