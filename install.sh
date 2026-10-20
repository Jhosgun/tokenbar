#!/bin/sh
set -eu

REPO="Jhosgun/tokenbar"
API_URL="https://api.github.com/repos/$REPO"
SKIP_SHA="${TOKENBAR_SKIP_SHA:-0}"
LOCAL_ZIP="${TOKENBAR_ZIP:-}"
REQUESTED_VERSION="${TOKENBAR_VERSION:-}"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

if [ "$(uname -s)" != "Darwin" ]; then
  fail "TokenBar solo funciona en Mac con macOS 14 o superior."
fi

MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null) || fail "No se pudo comprobar la versión de macOS."
MACOS_MAJOR=${MACOS_VERSION%%.*}
case "$MACOS_MAJOR" in
  ''|*[!0-9]*) fail "No se pudo interpretar la versión de macOS: $MACOS_VERSION." ;;
esac
if [ "$MACOS_MAJOR" -lt 14 ]; then
  fail "TokenBar requiere macOS 14 o superior; este Mac usa macOS $MACOS_VERSION."
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tokenbar-install.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

ZIP_PATH="$WORK_DIR/TokenBar.zip"
CHECKSUM_PATH="$WORK_DIR/TokenBar.zip.sha256"
VERSION=""

if [ -n "$LOCAL_ZIP" ]; then
  [ -f "$LOCAL_ZIP" ] || fail "No existe el zip local: $LOCAL_ZIP"
  ditto "$LOCAL_ZIP" "$ZIP_PATH"
  if [ -n "$REQUESTED_VERSION" ]; then
    VERSION=${REQUESTED_VERSION#v}
  else
    ZIP_NAME=${LOCAL_ZIP##*/}
    case "$ZIP_NAME" in
      TokenBar-*.zip) VERSION=${ZIP_NAME#TokenBar-}; VERSION=${VERSION%.zip} ;;
      *) VERSION="local" ;;
    esac
  fi
  if [ -f "$LOCAL_ZIP.sha256" ]; then
    ditto "$LOCAL_ZIP.sha256" "$CHECKSUM_PATH"
  fi
else
  RELEASE_JSON="$WORK_DIR/release.json"
  if [ -n "$REQUESTED_VERSION" ]; then
    VERSION=${REQUESTED_VERSION#v}
    RELEASE_API="$API_URL/releases/tags/v$VERSION"
  else
    RELEASE_API="$API_URL/releases/latest"
  fi

  printf 'Consultando la release de TokenBar…\n'
  curl -fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "$RELEASE_API" -o "$RELEASE_JSON" || fail "No se pudo consultar $RELEASE_API"
  TAG=$(plutil -extract tag_name raw -o - "$RELEASE_JSON" 2>/dev/null) || fail "La respuesta de GitHub no contiene una release válida."
  VERSION=${TAG#v}

  ZIP_URL="https://github.com/$REPO/releases/download/v$VERSION/TokenBar-$VERSION.zip"
  CHECKSUM_URL="$ZIP_URL.sha256"
  printf 'Descargando TokenBar %s…\n' "$VERSION"
  curl -fL "$ZIP_URL" -o "$ZIP_PATH" || fail "No se pudo descargar $ZIP_URL"
  if ! curl -fsSL "$CHECKSUM_URL" -o "$CHECKSUM_PATH"; then
    rm -f "$CHECKSUM_PATH"
  fi
fi

if [ -f "$CHECKSUM_PATH" ]; then
  IFS=' ' read -r EXPECTED_SHA _ < "$CHECKSUM_PATH" || true
  [ -n "${EXPECTED_SHA:-}" ] || fail "El asset .sha256 no contiene ningún hash."
  ACTUAL_SHA=$(shasum -a 256 "$ZIP_PATH")
  ACTUAL_SHA=${ACTUAL_SHA%% *}
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "El sha256 del zip no coincide; se canceló la instalación."
  printf 'sha256 verificado.\n'
else
  if [ "$SKIP_SHA" != "1" ]; then
    fail "La release no tiene un asset .sha256. Reintenta con TOKENBAR_SKIP_SHA=1 solo si confías en el zip."
  fi
  printf 'Aviso: instalando sin verificar sha256 porque TOKENBAR_SKIP_SHA=1.\n' >&2
fi

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR" || fail "No se pudo descomprimir el zip."
APP_PATH="$EXTRACT_DIR/TokenBar.app"
[ -d "$APP_PATH" ] || fail "El zip no contiene TokenBar.app."
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || fail "TokenBar.app no contiene un Info.plist válido."

if [ -w /Applications ]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi
DESTINATION="$INSTALL_DIR/TokenBar.app"

pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null || true
rm -rf "$DESTINATION"
ditto "$APP_PATH" "$DESTINATION" || fail "No se pudo instalar TokenBar en $INSTALL_DIR."
xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true
if open "$DESTINATION"; then
  printf 'TokenBar %s quedó instalada en %s y ya está abierta.\n' "$VERSION" "$DESTINATION"
else
  printf 'Aviso: TokenBar %s quedó instalada en %s, pero no se pudo abrir automáticamente. Ábrela manualmente desde %s.\n' \
    "$VERSION" "$DESTINATION" "$DESTINATION" >&2
fi

printf 'TokenBar no está notarizada: el instalador quitó la cuarentena para evitar el aviso de desarrollador no verificado.\n'
