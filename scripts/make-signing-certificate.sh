#!/bin/sh
# Makes the self-signed certificate "onlymuse local" once, so every helper build keeps its Automation permission.
set -eu

name="onlymuse local"

if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "The certificate \"$name\" is in the Keychain."
  exit 0
fi

umask 077
folder=$(mktemp -d)
trap 'rm -rf "$folder"' EXIT

# The macOS openssl writes a .p12 file the Keychain can read. Homebrew's openssl 3 may not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -keyout "$folder/key.pem" -out "$folder/certificate.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

password=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$folder/key.pem" -in "$folder/certificate.pem" \
  -name "$name" -out "$folder/identity.p12" -passout "pass:$password"

security import "$folder/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$password" -T /usr/bin/codesign

echo "Made the certificate \"$name\"."
