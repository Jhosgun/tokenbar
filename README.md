# TokenBar

App de barra de menú para macOS que muestra el consumo de tokens y la cuota restante de tus
herramientas de IA. Vive en la barra, no aparece en el Dock, y el ícono señala la presión de
cuota. Nativa y sin dependencias externas.

## Instalar

La forma directa, sin compilar ni instalar dependencias:

```sh
curl -fsSL https://raw.githubusercontent.com/Jhosgun/tokenbar/main/install.sh | sh
```

Con Homebrew:

```sh
brew trust jhosgun/tap
brew install --cask jhosgun/tap/tokenbar
```

O compílala tú: `git clone https://github.com/Jhosgun/tokenbar.git && cd tokenbar && make install`.

Desde la primera ejecución, TokenBar se abre sola al iniciar sesión; puedes desactivarlo en Preferencias.

La app **no está notarizada** por Apple. El instalador directo quita la cuarentena; con
Homebrew o el zip, macOS puede avisar la primera vez. Las tres vías y qué hacer con ese
aviso están en [`docs/INSTALL.md`](docs/INSTALL.md).

## Requisitos

- macOS 14 o superior.
- Xcode 26 (el proyecto usa `objectVersion = 77` y Swift 6 language mode).

## Build y run

Desde Xcode: abrir `TokenBar.xcodeproj`, seleccionar el scheme **TokenBar** y ⌘R.

Desde la terminal:

```sh
xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Release build
```

Para saber dónde quedó el `.app`, agrega `-derivedDataPath build` al comando y ábrelo:

```sh
open build/Build/Products/Release/TokenBar.app
```

La app está firmada ad-hoc (`CODE_SIGN_IDENTITY = "-"`), sin notarización: es para uso
personal en tu propia máquina. Como `LSUIElement = YES`, no hay ícono en el Dock ni ventana
principal — para salir, usa el menú ⚙︎ del popover.

## Tests

```sh
xcodebuild test -project TokenBar.xcodeproj -scheme TokenBar -destination 'platform=macOS'
```

## Arquitectura

El proyecto usa **synchronized root groups**: cualquier archivo `.swift` que dejes dentro de
`TokenBar/` o `TokenBarTests/` entra al target automáticamente, sin tocar Xcode.

| Carpeta | Qué contiene |
|---|---|
| `TokenBar/TokenBarApp.swift` | `@main`: el `MenuBarExtra` (estilo `.window`), el ícono reactivo y la ventana de Preferencias. |
| `TokenBar/App/` | `UsageViewModel`: `@MainActor @Observable`, corre los collectors cada 30 s y expone consumo y límites. |
| `TokenBar/Models/` | Tipos compartidos: `AppSource`, `UsageRecord` + `DayKey`, `Pricing`, `TokenFormatter`. |
| `TokenBar/Collectors/` | El protocolo `UsageCollector` (+ `CollectorStatus`/`CollectorResult`) y los collectors con fuente de tokens. Cada uno devuelve solo deltas nuevos y nunca lanza. |
| `TokenBar/Storage/` | Dos actores: `UsageStore` (acumula por día y persiste `usage.json`) y `CollectorStateStore` (offsets, dedup y bootstrap en `state.json`). |
| `TokenBar/Views/` | `DashboardView` (popover 300×640) con la sección Estadísticas, sus gráficas y tabla compacta; además de las filas de herramientas, `SparklineView` y `PreferencesView`. |
| `TokenBar/Support/` | Utilidades transversales sin lógica de negocio, como el acceso al Keychain. |
| `TokenBar/Resources/` | `Assets.xcassets`. |
| `TokenBarTests/` | Tests unitarios (Swift Testing) de modelos, acumulación por día y parsing. |

Las gráficas de **Estadísticas** viven dentro del mismo popover, debajo del resumen semanal:
permiten elegir 7, 30 o 90 días, agrupar por herramienta o modelo y alternar entre acumulado
y consumo diario sin abrir una ventana aparte.

`CONTRACT.md` es la fuente de verdad de los tipos compartidos. La arquitectura completa,
con diagramas del ciclo de refresco, las fuentes por herramienta, el modelo de datos y la
distribución, está en [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md).

## Fuentes de datos

- **Claude Code** — lee los transcripts JSONL de `~/.claude/projects/**/*.jsonl`. La lectura
  es incremental (guarda el byte offset de cada archivo y solo parsea lo nuevo) y deduplica
  por `message.id` + `requestId`. En el primer arranque solo mira archivos modificados hoy,
  para no re-procesar todo el historial. Los duplicados aparentes son parciales de streaming del mismo mensaje, con el output
  creciendo línea a línea; el collector lleva una marca de agua para no perderlo ni contarlo dos veces.
- **Cursor** — no hay tokens en archivos locales; se consulta la API de uso de cursor.com con
  la sesión que Cursor guarda en su `state.vscdb` (se lee en solo lectura, no hay que pegar
  nada). Cursor actualiza cada evento mientras el turno sigue: el collector guarda una foto
  por evento y suma solo el crecimiento.
- **Codex, Command Code y OpenCode** — leen sus sesiones locales (JSONL o SQLite) y
  deduplican por id de respuesta/mensaje.
- **Antigravity** — sin collector de tokens; su cuota se consulta en el endpoint de Google
  con el token que el CLI `agy` guarda en el llavero (respaldo: `agy -p /usage`).

## Privacidad

Todo ocurre en tu Mac: no hay servidor propio, ni telemetría, ni cuenta que crear. TokenBar
lee **contadores de tokens** (input, output, caché) y el id del modelo, nunca el contenido de
tus prompts ni de tus respuestas.

Sí hace red, y conviene decirlo claro: consulta la cuota de cada proveedor **en su propia
API y con tus propias credenciales** — Anthropic, ChatGPT (Codex), Cursor, Command Code y
OpenCode Go —, como máximo una vez cada 5 minutos. Antigravity se consulta ejecutando su
CLI, sin red propia. Nada sale hacia ningún otro destino.

La lista completa, ruta por ruta y endpoint por endpoint, está en
[`docs/PRIVACY.md`](docs/PRIVACY.md), junto con las advertencias sobre los endpoints no
documentados.

## Datos

| Archivo | Para qué |
|---|---|
| `~/Library/Application Support/TokenBar/usage.json` | Consumo acumulado por app y por día (se purgan los registros de más de 90 días). |
| `~/Library/Application Support/TokenBar/state.json` | Estado de los collectors: offsets por archivo, ids ya vistos y marcas de bootstrap. |

Para resetear todo (la app vuelve a empezar desde cero, contando solo lo de hoy):

```sh
rm -rf ~/Library/Application\ Support/TokenBar
```
