# Integración con main

Integración preparada el 6 de septiembre de 2026 en `integration/perf-main`.
La versión final combina `main` en `5ace06f` con `perf/echo-tail` en `22198c9`.
Incluye el scroll por teclado de `aa07123` y el socket de desarrollo separado
de `5ace06f`.

El candidato inicial `a638267`, basado en `667f311`, quedó en su worktree mientras
se terminaban los cambios locales de scroll. La integración final conserva esa
implementación de `main` y vuelve a validar el conjunto antes de avanzar la rama.
Los cambios locales de `dev/config.lua` y Asteroids quedan fuera.

## Resoluciones

- `runtime/client/session.zig` conserva los colores del terminal y el estado
  pendiente de búsqueda. Era el único conflicto textual.
- Se conserva el módulo `kitty_protocol` y el arranque con negociación OSC 10/11.
- El arranque despacha las sondas mediante `presentation_lifecycle.pumpOutput`
  antes de esperar eventos. Sin esta llamada, la salida asíncrona podía retener
  las sondas hasta otro evento, incluido su propio vencimiento. La prueba nueva
  de arranque asíncrono falló antes de la reparación y pasa después.
- `667f311` incluía `scroll_pane` sin cubrir tres switches. Se reprodujo el fallo
  sobre ese commit limpio. La reparación provisional de `a638267` queda
  sustituida por la implementación de `aa07123`: comparte la política de rueda
  con el ratón, admite viewport, teclas de pantalla alternativa y reportes SGR,
  y rechaza scroll en la autorización y codificación de efectos de plugins.
  Los archivos de acciones, configuración Lua y plugins coinciden con `main`.
  Se conserva además la prueba de integración de límites y orden del viewport.

## Validación local

En macOS arm64 con Zig 0.16.0:

- Debug y ReleaseFast: 3.523/3.523 pruebas, 86/86 pasos en cada suite.
  El candidato inicial había pasado 3.512/3.512.
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

Evidencia final: [main-integration/final/](main-integration/final/). Todas las
comprobaciones anteriores se repitieron tras incorporar `5ace06f`. La evidencia
del candidato inicial permanece en [main-integration/](main-integration/).
Los JSON conservan las muestras; los logs están comprimidos. El manifiesto
`main-integration/sha256.json` permite comprobar la integridad de ambas series.

Estas son comprobaciones funcionales de integración, no una comparación de
rendimiento. No hay nueva serie AB/BA ni gate Ubuntu nativo. Sigue pendiente la
regresión p99 de aplicación pausada de +17,50% documentada en [echo.md](echo.md).
La integración solicitada no convierte ese resultado en una mejora aprobada.
