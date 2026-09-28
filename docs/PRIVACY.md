# Privacidad: qué lee TokenBar y con quién habla

TokenBar no tiene servidor propio, no manda telemetría y no guarda nada fuera de tu Mac.
Este documento lista **todo** lo que lee y **todas** las conexiones que hace, para que no
tengas que creer en la palabra de nadie: cada afirmación de aquí se puede comprobar en el
código de `TokenBar/Limits/` y `TokenBar/Collectors/`.

## Lo que lee de tu disco

| Ruta | Para qué | Modo |
|---|---|---|
| `~/.claude/projects/**/*.jsonl` | Contar tokens de Claude Code: solo los contadores (`input`, `output`, caché) y el id del modelo | Lectura, incremental |
| `~/.claude.json` → `cachedUsageUtilization` | Cuota de Claude (5 h, semanal, por modelo) que el propio Claude Code deja en disco | Lectura, **solo esa clave** |
| Llavero, `Claude Code-credentials` | Token OAuth de Claude, solo si hay que consultar la cuota por red | Lectura |
| `~/.codex/auth.json` | Token de ChatGPT para la cuota de Codex | Lectura, nunca se escribe |
| `~/.codex/sessions/**/rollout-*.jsonl` | Respaldo de la cuota de Codex cuando no hay red: solo el bloque `rate_limits` de la cola del archivo | Lectura |
| `~/Library/Application Support/Cursor/.../state.vscdb` | Token de sesión de Cursor | Lectura, SQLite en modo `ro` |
| `~/.commandcode/auth.json` | Llave de Command Code | Lectura |
| `~/.local/share/opencode/auth.json` | Llave de OpenCode Go | Lectura |
| `agy -p /usage` | Cuota de Antigravity: su CLI la imprime, es de solo lectura y no gasta cuota | Ejecución cada 15 min |

**Nunca** se lee el contenido de tus conversaciones, ni prompts, ni respuestas, ni el código
sobre el que trabajas. De los transcripts de Claude Code solo se extraen números.

## Lo que escribe

Dos archivos, únicamente en `~/Library/Application Support/TokenBar/`:

- `usage.json` — tokens acumulados por herramienta y por día (se purga a los 90 días).
- `state.json` — hasta dónde leyó cada archivo, para no recontar.

Para borrarlo todo: `rm -rf ~/Library/Application\ Support/TokenBar`.

## Con quién habla

Solo con las APIs de tus propios proveedores, autenticado con **tus** credenciales, y solo
para preguntar por tu cuota. Como máximo una vez cada 5 minutos por proveedor, y hay
proveedores que van mucho más espaciados.

| Destino | Qué pregunta |
|---|---|
| `api.anthropic.com/api/oauth/usage` | Cuota de Claude. Solo como respaldo: primero se usa la caché local |
| `chatgpt.com/backend-api/wham/usage` | Cuota de Codex |
| `cursor.com/api/usage-summary` y `/api/dashboard/get-filtered-usage-events` | Cuota y consumo de Cursor |
| `api.commandcode.ai/alpha/*` | Cuota y créditos de Command Code |
| `opencode.ai/zen/go/v1/usage` | Cuota de OpenCode Go |

No hay ningún otro destino: ni analítica, ni reporte de errores, ni actualizaciones
automáticas. Si desconectas la red, la app sigue mostrando tus tokens (que salen de
archivos locales) y la última cuota conocida, marcada con su antigüedad.

## Advertencias honestas

- **Varios de esos endpoints son internos y no están documentados** por sus dueños. Pueden
  cambiar o dejar de funcionar sin aviso; cuando eso pasa, la fila muestra un error en vez
  de inventar cifras. El de Cursor, además, vive en una zona gris de sus términos de
  servicio, que prohíben extraer datos de forma automatizada; se consulta con tu propia
  sesión y solo tu propio consumo, pero decide tú si te sirve así.
- **El costo que muestra es equivalente a precio de API**, no lo que pagas. Si estás en una
  suscripción, el dato útil es el porcentaje de cada ventana.
- **La app no está notarizada por Apple** (ver `docs/INSTALL.md`), así que macOS avisará la
  primera vez. Puedes compilarla tú desde el código si prefieres no confiar en el binario.
