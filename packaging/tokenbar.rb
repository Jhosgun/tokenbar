# Fórmula del cask para el tap Jhosgun/homebrew-tap.
# Copiar a ese repo como Casks/tokenbar.rb y actualizar version y sha256 en cada release.
cask "tokenbar" do
  version "REEMPLAZAR_VERSION"
  sha256 "REEMPLAZAR_SHA256"

  url "https://github.com/Jhosgun/tokenbar/releases/download/v#{version}/TokenBar-#{version}.zip"
  name "TokenBar"
  desc "Menu bar app that shows token usage and remaining quota of your AI coding tools"
  homepage "https://github.com/Jhosgun/tokenbar"

  depends_on macos: ">= :sonoma"

  app "TokenBar.app"

  zap trash: [
    "~/Library/Application Support/TokenBar",
  ]

  caveats <<~EOS
    TokenBar no está firmada con una cuenta de Apple Developer, así que macOS la bloquea
    la primera vez. Si al abrirla ves el aviso, cualquiera de estas dos sirve:

      xattr -dr com.apple.quarantine "/Applications/TokenBar.app"

    o instalarla sin cuarentena desde el principio:

      brew install --cask --no-quarantine jhosgun/tap/tokenbar

    Si prefieres no confiar en el binario, el código está en el repo y se compila con
    `make install`.
  EOS
end
