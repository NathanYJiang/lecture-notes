#!/bin/bash
# One-time: creates a self-signed "LectureNotes Dev" code-signing identity in your login keychain.
# build.sh picks it up automatically, so the app keeps the same identity across rebuilds and
# macOS stops re-asking for Keychain/mic access. Not trusted system-wide; only codesign can use the key.
set -euo pipefail
NAME="LectureNotes Dev"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:lecturenotes
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P lecturenotes -T /usr/bin/codesign

echo "Created \"$NAME\". Now run: ./build.sh --install"
