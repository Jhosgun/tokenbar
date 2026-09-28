# TokenBar — build, prueba, instalación y empaquetado.
#
#   make build      compila en Release
#   make test       corre los tests
#   make run        compila e inicia la app
#   make install    instala en /Applications (reemplaza y reinicia si estaba corriendo)
#   make uninstall  la quita de /Applications
#   make release VERSION=1.0.0   empaqueta el zip y escribe su sha256
#   make clean      borra lo compilado

PROJECT      := TokenBar.xcodeproj
SCHEME       := TokenBar
DERIVED      := build
APP          := $(DERIVED)/Build/Products/Release/TokenBar.app
INSTALL_DIR  := /Applications
DIST         := dist

.PHONY: all build test run install uninstall release clean check-xcode

all: build

check-xcode:
	@command -v xcodebuild >/dev/null 2>&1 || { \
		echo "Falta xcodebuild. Instala Xcode desde la App Store y luego:"; \
		echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1; }
	@xcodebuild -version >/dev/null 2>&1 || { \
		echo "xcodebuild está apuntando a las Command Line Tools, no a Xcode:"; \
		echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1; }

build: check-xcode
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) build | tail -1
	@echo "App: $(APP)"

test: check-xcode
	@xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) 2>&1 \
		| grep -E "Test run with|Executed|error:|\*\* TEST" || true

run: build
	@pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null || true
	@open "$(APP)"
	@echo "TokenBar corriendo. Busca su ícono en la barra de menú."

install: build
	@echo "Instalando en $(INSTALL_DIR)…"
	@pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/TokenBar.app"
	@cp -R "$(APP)" "$(INSTALL_DIR)/TokenBar.app"
	@open "$(INSTALL_DIR)/TokenBar.app"
	@echo "Listo. TokenBar quedó en $(INSTALL_DIR) y ya está corriendo."

uninstall:
	@pkill -f "TokenBar.app/Contents/MacOS/TokenBar" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/TokenBar.app"
	@echo "Desinstalada. Tus datos siguen en ~/Library/Application Support/TokenBar"
	@echo "(bórralos con: rm -rf ~/Library/Application\\ Support/TokenBar)"

# El zip se hace con ditto para conservar los metadatos del bundle; `zip` a secas
# rompe la firma ad-hoc y macOS rechaza la app al abrirla.
release: build
ifndef VERSION
	$(error Falta VERSION. Uso: make release VERSION=1.0.0)
endif
	@mkdir -p $(DIST)
	@rm -f "$(DIST)/TokenBar-$(VERSION).zip"
	@ditto -c -k --keepParent "$(APP)" "$(DIST)/TokenBar-$(VERSION).zip"
	@shasum -a 256 "$(DIST)/TokenBar-$(VERSION).zip" | tee "$(DIST)/TokenBar-$(VERSION).zip.sha256"
	@echo "Paquete: $(DIST)/TokenBar-$(VERSION).zip"

clean:
	@rm -rf $(DERIVED) $(DIST)
	@echo "Limpio."
