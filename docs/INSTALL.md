# Instalar TokenBar

Requisitos: **macOS 14 (Sonoma) o superior**. Solo hace falta Xcode si la vas a compilar tú.

## 1. Homebrew (recomendado)

```sh
brew install --cask jhosgun/tap/tokenbar
```

Para actualizar: `brew upgrade --cask tokenbar`. Para quitarla con todos sus datos:
`brew uninstall --zap --cask tokenbar`.

## 2. Descargar el zip

Baja `TokenBar-<versión>.zip` de la [última release][releases], descomprímelo y arrastra
`TokenBar.app` a `/Applications`. En la página de cada release está el `sha256` del
archivo, por si lo quieres verificar:

```sh
shasum -a 256 ~/Downloads/TokenBar-<versión>.zip
```

## 3. Compilar desde el código

Necesitas Xcode 16 o superior.

```sh
git clone https://github.com/Jhosgun/tokenbar.git
cd tokenbar
make install
```

Eso compila, la deja en `/Applications` y la abre. Es la vía sin advertencias de macOS,
y la que te deja leer exactamente lo que estás corriendo. `make uninstall` la quita.

## El aviso de macOS la primera vez

**TokenBar no está notarizada por Apple**, porque no hay una cuenta de Apple Developer
detrás (cuesta 99 USD al año). El binario va firmado ad-hoc, así que al abrirlo por
primera vez macOS dirá que no puede verificar al desarrollador. Dos formas de seguir:

- Clic derecho sobre la app → **Abrir** → **Abrir** de nuevo en el diálogo. Solo la
  primera vez.
- O quitarle la marca de cuarentena:

  ```sh
  xattr -dr com.apple.quarantine /Applications/TokenBar.app
  ```

Con Homebrew puedes evitarlo desde el inicio con
`brew install --cask --no-quarantine jhosgun/tap/tokenbar`.

Esa marca existe para protegerte de binarios descargados de internet, así que sáltatela
solo con software cuyo origen conozcas. Si prefieres no hacerlo, usa la opción 3 y
compílala tú: el código es el mismo que produce el binario de las releases.

## Primer arranque

1. Aparece un ícono en la barra de menú. La app no sale en el Dock.
2. Clic en el ícono para ver una fila por herramienta, y clic en una fila para desplegar
   sus ventanas de cuota.
3. Para la cuota de Claude, macOS pedirá permiso para leer una credencial del llavero.
   Dale **Permitir siempre**. Si la niegas, esa fila dirá "No configurado"; se corrige en
   Acceso a Llaveros, buscando `Claude Code-credentials`.
4. Cada herramienta aparece solo si la tienes instalada y con sesión iniciada. Lo que lee
   de tu Mac está detallado en [PRIVACY.md](PRIVACY.md).

## Desinstalar

```sh
brew uninstall --zap --cask tokenbar   # si la instalaste con Homebrew
# o
make uninstall                          # si la compilaste
rm -rf ~/Library/Application\ Support/TokenBar   # sus datos
```

[releases]: https://github.com/Jhosgun/tokenbar/releases/latest
