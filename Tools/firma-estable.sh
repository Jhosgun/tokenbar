#!/bin/bash
# Hace que el permiso del llavero sobreviva a las recompilaciones de TokenBar.
#
# Por qué hace falta: la app se firma "ad-hoc", así que cada recompilación produce una
# identidad distinta. El "Always Allow" del llavero se ata a la firma, de modo que al
# recompilar deja de valer y macOS vuelve a preguntar. Firmando siempre con el mismo
# certificado local, el permiso se concede una vez y ya.
#
# Pide tu contraseña dos veces: una para confiar en el certificado y otra para dejar que
# `codesign` use su llave privada. Es local y reversible (ver "Para deshacer" al final).
#
# Uso:  ./Tools/firma-estable.sh

set -euo pipefail

CERT_NAME="TokenBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/build/TokenBar.app"

echo "==> 1/4  Certificado local"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "    ya existe, se reutiliza"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -days 3650 -nodes -config "$WORK/ext.cnf" 2>/dev/null
    # Cifrado legacy: `security` no lee los PKCS#12 modernos de OpenSSL 3.
    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout pass:tokenbar -name "$CERT_NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P tokenbar -T /usr/bin/codesign -A
    echo "    creado"
fi

echo "==> 2/4  Confiar en el certificado para firmar código (pide tu contraseña)"
CERT_PEM="$(mktemp)/cert.pem"; mkdir -p "$(dirname "$CERT_PEM")"
security find-certificate -c "$CERT_NAME" -p > "$CERT_PEM"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"

echo "==> 3/4  Permitir que codesign use la llave (pide tu contraseña)"
read -rsp "    Contraseña del llavero (login): " KEYCHAIN_PASSWORD; echo
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
unset KEYCHAIN_PASSWORD

echo "==> 4/4  Firmar la app"
if [ ! -d "$APP" ]; then
    echo "    no existe $APP — compílala primero:"
    echo "    xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Release build"
    exit 1
fi
HASH="$(security find-identity -v -p codesigning | grep "$CERT_NAME" | head -1 | awk '{print $2}')"
if [ -z "$HASH" ]; then
    echo "    el certificado sigue sin ser válido para firmar; revisa los pasos 2 y 3"
    exit 1
fi
xattr -cr "$APP"
codesign --force --sign "$HASH" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Authority" || true

echo
echo "Listo. Reinicia TokenBar y, cuando macOS pregunte por el llavero, pulsa"
echo "\"Always Allow\" UNA vez. A partir de ahí no vuelve a preguntar, ni siquiera"
echo "después de recompilar (siempre que se firme con este mismo certificado)."
echo
echo "Para deshacer:"
echo "  security delete-certificate -c \"$CERT_NAME\" \"$KEYCHAIN\""
