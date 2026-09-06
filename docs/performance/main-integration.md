# Integración con main

Candidato preparado el 6 de septiembre de 2026 en `integration/perf-main`,
combinando `main` en `667f311` con `perf/echo-tail` en `22198c9`.
No se avanzó `main`: durante la validación aparecieron cambios locales en
`actions.zig` y `generation.zig` que se solapan con la reparación descrita abajo.
Es necesario reconciliar ese trabajo antes de integrar este candidato.

## Resoluciones

- `runtime/client/session.zig` conserva los colores del terminal y el estado
  pendiente de búsqueda. Era el único conflicto textual.
- Se conserva el módulo `kitty_protocol` y el arranque con negociación OSC 10/11.
- El arranque despacha las sondas mediante `presentation_lifecycle.pumpOutput`
  antes de esperar eventos. Sin esta llamada, la salida asíncrona podía retener
  las sondas hasta otro evento, incluido su propio vencimiento. La prueba nueva
  de arranque asíncrono falló antes de la reparación y pasa después.
- `main` ya incluía `scroll_pane` sin cubrir tres switches. Se reprodujo el fallo
  compilando `test-frontend` sobre `667f311` limpio. El candidato conecta la acción
  al handler de viewport existente, valida el constructor Lua y mantiene el
  rechazo de efectos de plugin sin codificación. Incluye pruebas de direcciones,
  límites y orden de mensajes. El trabajo local simultáneo propone otra conexión
  para esta acción; no se ha sustituido ni incorporado a este candidato.

## Validación local

En macOS arm64 con Zig 0.16.0:

- Debug y ReleaseFast: 3.512/3.512 pruebas, 86/86 pasos en cada suite.
- Nueve pruebas Python.
- Build ReleaseFast con diagnósticos desactivados y activados, `echo-probe` y
  `zig build bench` completados.
- Cien muestras por escenario de eco del kernel, aplicación raw y dos floods.
  Las 300 completaron la validación visible de eco y borrado sin timeout.
- Transferencia gráfica RGBA 3840×2160 con zlib, 33.177.600 bytes reconstruidos
  y hash de píxeles verificado.
- Host bloqueado: 32/32 entradas reenviadas antes de volver a drenar su salida.
- Los cinco runtimes terminaron con sus hijos y eliminaron sus sockets.
- Los 789 hashes de evidencia histórica siguen coincidiendo.

La primera ejecución de tests también encontró límites de longitud de socket
Unix en el path largo del worktree. Las suites completas se repitieron desde
`/tmp/telar-mi`. Los fallos iniciales se conservan junto con los resultados finales.

Evidencia: [main-integration/](main-integration/). Los JSON conservan las muestras;
los logs están comprimidos. `sha256.json` permite comprobar su integridad.

Estas son comprobaciones funcionales de integración, no una comparación de
rendimiento. No hay nueva serie AB/BA ni gate Ubuntu nativo. Sigue pendiente la
regresión p99 de aplicación pausada de +17,50% documentada en [echo.md](echo.md).
La integración solicitada no convierte ese resultado en una mejora aprobada.
