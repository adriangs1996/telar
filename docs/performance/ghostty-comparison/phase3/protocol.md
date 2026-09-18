# Fase 3: reducir latencia conservando caudal

Protocolo propuesto antes de medir. A es `/tmp/tgb-phase2-stable/bin/telar`; B será `/tmp/tgb-phase3-candidate/bin/telar`. El SHA-256 conocido de A es `f9dd3cf7a007f9cca462fb2b9050b9e07b08e5eaa4246f494c1fd1c186f6b822`. No se han ejecutado compilaciones, apps ni mediciones al preparar este documento.

## Fuente y herramientas

El candidato se compila en ReleaseFast con el GUI congelado de `/tmp/tgb-diagnostic-source`, igual que A. Antes de construirlo, guardar base Git, diff completo, hashes de fuentes relevantes y comando de build. No incorporar las ediciones concurrentes del GUI del workspace. Registrar el SHA del binario construido y conservarlo durante toda la serie. No sobrescribir el baseline, su prefijo de build ni `/tmp/tgb-p3-setup`.

`/tmp/tgb-phase3-native.py` es una copia exacta de `docs/performance/ghostty-comparison/phase2/raw/scripts/native-final.py`. Conserva la interfaz parametrizable; el ejemplo de su docstring todavía usa el nombre de fase 2. No compila, firma ni modifica bundles. Reutiliza el probe, config y app privada de `/tmp/tgb-p3-setup`. La app privada sigue siendo una dependencia del runner aunque no se solicite una nueva comparación con Ghostty.

El runner copia las herramientas al directorio de resultados y registra sus SHA. Verifica que la fuente Objective-C coincida con la que produjo el probe, que el config no cambie y que los binarios y artefactos compartidos mantengan sus SHA hasta terminar. Para cada nueva serie, guardar también este protocolo y un manifest de procedencia del candidato. Mantener idénticas herramientas entre A y B.

## Exploración

Antes de medir, ejecutar las pruebas de publicación, input y timer, la integración del último frame sin nuevo input y la limpieza con timer aparcado. Las cargas se ejecutan después, en una ventana exclusiva, sin builds, tests, profiler ni otras apps de benchmark en paralelo.

Una exploración por candidato usa dos rondas, AB y BA, de `single`, `splits-load` y `tabs-load`, con 30 muestras útiles y 20 warmup por corrida. Los productores secundarios usan corpus variable y solicitan 1 MiB/s por pane. El `single` incluye también ASCII y ANSI de 8 MiB. Añadir dos pares de `single` con patrón repetido y una muestra útil de latencia; esa latencia sólo acompaña al ensayo de caudal y no se interpreta.

Guardar cada candidato y cada exploración con nombre y SHA propios. No reutilizar estas rondas en la confirmación final. Ningún umbral se ajusta al ver sus resultados. La exploración puede descartar una hipótesis por regresión evidente, pero no demuestra no inferioridad.

```sh
python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools tools \
  --output /tmp/tgb-p3-explore-variable --rounds 2 --samples 30 \
  --cases single splits-load tabs-load --text-pattern variable \
  --background-mib-per-second 1 --record-rate-misses

python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools tools \
  --output /tmp/tgb-p3-explore-repeat --rounds 2 --samples 1 \
  --cases single --text-pattern repeat --record-rate-misses
```

## Confirmación final

Congelar el candidato antes de empezar. Cuatro rondas con orden AB, BA, AB, BA por caso. El runner visita `single`, `splits-load`, `tabs-load` en cada ronda. No añadir nuevas corridas de Ghostty: el contraste causal de esta fase es B contra A.

- Variable: cuatro rondas, tres casos, 100 muestras útiles y 20 warmup. Son 24 corridas, 2400 muestras útiles y 480 warmup. Cada versión aporta 400 muestras útiles por caso.
- Repetido: cuatro rondas de `single`, 40 muestras útiles y 20 warmup. Son ocho corridas, 320 muestras útiles y 160 warmup. Esta extensión es opcional para latencia, pero medir sus cuatro pares de caudal de 8 MiB es necesario para afirmar conservación en ambos patrones. Si se omite su latencia, usar `--samples 1` y excluir esas muestras de las conclusiones.
- Sostenido: cuatro rondas AB, BA, AB, BA con 64 MiB ASCII y 64 MiB ANSI, en ambos patrones, mediante `tools/terminal_runtime_bench.py`. Son 16 corridas y 32 payloads. Alternar también el orden de patrones: repeat/variable en rondas pares y variable/repeat en impares. Se eligen cuatro pares para equilibrar el orden, en lugar de los tres usados en fase 2.

```sh
python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools tools \
  --output /tmp/tgb-p3-final-variable --rounds 4 --samples 100 \
  --cases single splits-load tabs-load --text-pattern variable \
  --background-mib-per-second 1 --record-rate-misses

python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools tools \
  --output /tmp/tgb-p3-final-repeat --rounds 4 --samples 40 \
  --cases single --text-pattern repeat --record-rate-misses
```

Cada corrida sostenida usa el siguiente comando, sustituyendo patrón, versión y ronda según el orden anterior. Ejecutarlo serialmente y con un directorio nuevo para cada corrida.

```sh
BENCH_TEXT_PATTERN=variable python3 tools/terminal_runtime_bench.py \
  --binary /tmp/tgb-phase3-candidate/bin/telar \
  --output /tmp/tgb-p3-sustained/0-variable-candidate --mib 64
```

La herramienta sostenida no genera por sí sola el manifest comparativo. El orquestador debe registrar el plan, hashes de binarios y herramientas antes/después, timestamps, código de salida, `result.json` y `shutdown.json`; abortar ante cambios o fallos y conservar todo lo producido. Validar en cada resultado los dos casos de 67.108.864 bytes, SHA idénticos por patrón/workload, PTY interior 111×33, `sampled=false`, `detached=false` y endpoint DSR. Verificar shutdown sin supervivientes antes de lanzar la siguiente corrida. No comparar directamente sus tasas con el GUI: es un TUI cuya salida anfitriona se drena por PTY, con trabajo de cliente distinto.

## Criterios previos

La unidad de análisis es el par de rondas completo. Para latencia, publicar p50/p95/p99 pooled, los percentiles de cada corrida y su rango, y diferencias B−A de p50 y p95 por ronda. Usar 10.000 remuestreos de pares, semilla 20260918, e IC percentil del 95%. El p99 es descriptivo con este tamaño. El objetivo principal es reducir p95 en `splits-load` y `tabs-load`; una mejora sólo se afirmará para un caso si su IC de diferencia queda por debajo de cero. Publicar también `single`, aunque empeore, y todas las colas y máximos. No seleccionar sólo el caso favorable.

Para caudal se fija un margen práctico de pérdida del 5%, separado por patrón y workload, y separado entre GUI 8 MiB y TUI sostenido 64 MiB. Para cada par i calcular `r_i = rate_B_i / rate_A_i`; el estimador es `R = exp(mean(log(r_i)))`. Publicar también todos los ratios, mediana y rango de las tasas originales.

El criterio operativo de no inferioridad exige que el límite inferior unilateral del 95% de R sea al menos 0,95 en cada uno de los cuatro estratos de GUI y los cuatro de sostenido. Obtenerlo como percentil 5 de 10.000 remuestreos de pares completos, semilla 20260918. Si el límite superior unilateral queda por debajo de 0,95, hay evidencia de regresión mayor que el margen; en otro caso el resultado es inconcluso. No basta que el IC incluya 1, ni que una diferencia incluya cero. Tampoco basta superar 80 MiB/s: ese objetivo absoluto no sustituye la comparación con A.

Con cuatro pares el bootstrap es discreto y su cobertura es frágil; este criterio es una regla operativa limitada a las cargas medidas, no una demostración de equivalencia o una garantía poblacional. Si resulta inconcluso, no cambiar margen, eliminar pares ni añadir rondas hasta obtener éxito. Proponer una nueva confirmación independiente y más larga, con tamaño cerrado antes de iniciarla, o informar la incertidumbre. Exigir todos los estratos evita compensar una regresión ANSI con una mejora ASCII.

## Validez, fallos y alcance

Fijar viewport 1000×700, escala y geometría PTY por caso y versión. Comprobar los cuatro arrays de foco, todos `true`, número exacto de muestras, marcador/renderer, `failed=0`, setup completo y ausencia de cambio de tamaño durante medición. El endpoint de latencia sigue siendo keyDown nativo hasta callback GPU del marcador verificado, no presentación física. ASCII y ANSI siguen midiendo escritura PTY hasta lectura de la respuesta DSR, no finalización GPU. El corpus se prepara y calcula su SHA antes del cronómetro.

Conservar los rate misses y todas sus muestras. No relajar tolerancia ni repetir para reemplazarlos. Mostrar checkpoints completos, tasas observadas y bloqueos de escritura; 1 MiB/s es una demanda por productor, no garantía de carga idéntica entre versiones. Una conclusión de latencia bajo carga comparable requiere revisar esas diferencias; la mejora obtenida reduciendo la carga efectiva del candidato no demuestra mejora del runtime.

El runner sólo permite reintentar el fallo de arranque sin ventana, sin panes y sin muestras; conserva sus registros. Foco, geometría, payload, cleanup u otros fallos invalidan la corrida y detienen la serie. Conservar intentos fallidos y motivo, sin mezclarlos con una confirmación completa. Los valores altos válidos permanecen en el análisis.

La validación final debe recalcular percentiles, comprobar emparejamiento y completar los hashes y limpieza. La comparación no mide todas las asignaciones, memoria máxima, bytes IPC ni pérdidas de observación. Repetir diagnósticos instrumentados si esos recursos cambian o si se quiere afirmar su conservación; no inferirla del caudal. Mantener pruebas del último frame, cancelación, independencia entre clientes y eco tras idle como requisitos de corrección separados del benchmark.

## Ajuste previo a la exploración

El setup de fase3 usa la sonda actual, que añade diagnóstico opt-in. Las comparaciones fijan `TGB_DRAW_DIAGNOSTICS=0`. Los diagnósticos aislados fijan `1` y no entran en los resultados principales. La exploración variable queda en 30 muestras útiles por corrida. La confirmación repetida usará `--samples 1`; sólo se interpreta su caudal. Estas decisiones se fijan antes de medir el candidato en parejas.
