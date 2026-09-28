# TokenBar

App de barra de menú para macOS que muestra el consumo de tokens y la cuota restante de tus
herramientas de IA. Vive en la barra, no aparece en el Dock, y el ícono señala la presión de
cuota. Nativa y sin dependencias externas.

## Instalar

```sh
brew trust jhosgun/tap
brew install --cask jhosgun/tap/tokenbar
```

O compílala tú: `git clone https://github.com/Jhosgun/tokenbar.git && cd tokenbar && make install`.

La app **no está notarizada** por Apple, así que macOS avisa la primera vez; las tres vías
de instalación y qué hacer con ese aviso están en [`docs/INSTALL.md`](docs/INSTALL.md).

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
| `TokenBar/Views/` | `DashboardView` (300×380), `AppRowView`, `SparklineView` (Swift Charts) y `PreferencesView`. |
| `TokenBar/Support/` | Utilidades transversales sin lógica de negocio, como el acceso al Keychain. |
| `TokenBar/Resources/` | `Assets.xcassets`. |
| `TokenBarTests/` | Tests unitarios (Swift Testing) de modelos, acumulación por día y parsing. |

`CONTRACT.md` es la fuente de verdad de los tipos compartidos; `plan.md` y `tasks.md`
describen el alcance y el orden de ejecución.

## Fuentes de datos

- **Claude Code** — lee los transcripts JSONL de `~/.claude/projects/**/*.jsonl`. La lectura
  es incremental (guarda el byte offset de cada archivo y solo parsea lo nuevo) y deduplica
  por `message.id` + `requestId`. En el primer arranque solo mira archivos modificados hoy,
  para no re-procesar todo el historial. Los duplicados aparentes son parciales de streaming del mismo mensaje, con el output
  creciendo línea a línea; el collector lleva una marca de agua para no perderlo ni contarlo dos veces.
- **Cursor** — no hay tokens en archivos locales; se consulta la API de uso de cursor.com con
  un token de sesión que pegas una vez en Preferencias y se guarda en el Keychain. Sin token,
  la fila muestra "No configurado" y no rompe nada.
- **Antigravity** — no tiene una fuente fiable de conteo de tokens; su cuota la obtiene
  `AntigravityLimitsProvider` mediante la CLI.

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
