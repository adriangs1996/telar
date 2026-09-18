# Primera mejora de caudal

El cliente GUI alcanzó **60,00 MiB/s en ASCII y 55,71 MiB/s en ANSI**, frente a
8,59 y 8,60 del original. Las ocho mediciones del candidato superaron 40 MiB/s;
la menor fue 53,24. Son medianas de cuatro rondas locales, no una garantía universal.

La optimización elimina una copia de 2,7 MB al consultar el crédito gráfico,
agrupa las lecturas del PTY que ya están disponibles y resuelve los colores por
defecto una vez por frame. El historial, la observación de agentes, los gráficos
y el protocolo de confirmaciones siguen activos.

## Confirmación con la GUI

Cuatro rondas AB/BA con los mismos ejecutables originales y nuevos. Ventana
nativa de 1000 × 700, panel de 111 × 31, mismo payload de 8 MiB por caso y mismo
endpoint DSR. El readback de GPU permanece activo en ambos ejecutables.

| Versión | ASCII, mediana [mín.; máx.] MiB/s | ANSI, mediana [mín.; máx.] MiB/s |
| --- | ---: | ---: |
| Original | 8,59 [7,79; 8,88] | 8,60 [8,47; 8,66] |
| Optimizada | 60,00 [54,44; 67,72] | 55,71 [53,24; 57,38] |

La relación entre medianas es 6,99× y 6,48× respectivamente. La cifra de
Ghostty de unos 83–87 MiB/s pertenece al [benchmark anterior](README.md).
No se volvió a medir Ghostty en esta serie ni se aisló el coste del socket.

[Datos individuales](phase1/raw/native/runs.json),
[estadísticas por ronda](phase1/raw/native/paired.json) y
[procedencia](phase1/raw/native/manifest.json).

## Latencia interactiva

Cuatro rondas por caso, 100 muestras por versión y ronda, más 20 respuestas de
calentamiento. Son 2.400 muestras medidas. El endpoint empieza en `keyDown`
y termina en el callback de GPU que verifica el píxel cambiado; no mide la
presentación física en el monitor. Todas las comprobaciones de foco pasaron.

| Caso | Versión | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| Un panel, después del caudal | Original | 8,08 ms | 21,39 ms | 27,39 ms |
| Un panel, después del caudal | Optimizada | 7,12 ms | 21,39 ms | 27,47 ms |
| Cuatro splits, tres con salida continua | Original | 18,27 ms | 31,35 ms | 35,55 ms |
| Cuatro splits, tres con salida continua | Optimizada | 16,50 ms | 29,03 ms | 35,74 ms |
| Cuatro pestañas, tres ocultas con salida continua | Original | 6,15 ms | 18,84 ms | 24,44 ms |
| Cuatro pestañas, tres ocultas con salida continua | Optimizada | 6,22 ms | 22,05 ms | 25,91 ms |

Son percentiles agrupados. Las diferencias medias entre percentiles por ronda,
optimizada menos original, usan 10.000 remuestreos de parejas completas,
semilla 20260918. Para p50: un panel −0,79 ms, IC95 [−1,11; −0,54]; splits
−1,52 ms [−2,97; −0,08]; pestañas +0,26 ms [−0,30; +0,85]. Para p95: un panel
−0,01 ms [−3,39; +3,38]; splits −2,38 ms [−4,56; −0,17]; pestañas +2,09 ms
[−0,57; +4,75]. Cuatro parejas limitan la precisión; no se estima IC para p99.

**No queda demostrada la ausencia de regresión en pestañas bajo carga.** Su
p95 agrupado aumenta, aunque el intervalo entre rondas incluye cero. Los
productores no limitan su caudal, por lo que el trabajo efectivo de ambas
versiones difiere. Estos datos no separan esa diferencia de una regresión de
planificación; será un control necesario para la siguiente etapa.

Se vuelve a medir el mismo binario original en esta sesión. Sus latencias
absolutas también difieren de las del informe anterior; la comparación válida
para este cambio es la de las parejas actuales. No se atribuye esa diferencia
a una causa concreta. [Resumen y validaciones](phase1/raw/native/summary.json).

## Separación de los cambios

Cuatro rondas con cuatro variantes, en orden cíclico de cuadrado latino.
Cada ejecución escribe 8 MiB ASCII y después 8 MiB ANSI. La TUI permanece
conectada a un PTY exterior de 111 × 35; el panel interior mide 111 × 33.
La herramienta drena la salida del cliente. No hay renderizador exterior.

El reloj termina al recibir la respuesta DSR a una consulta posterior al
payload. Mide procesamiento ordenado del flujo, sin esperar presentación
visible. Las mediciones no aíslan el coste del socket Unix.

| Cambio acumulado | ASCII, mediana [mín.; máx.] MiB/s | ANSI, mediana [mín.; máx.] MiB/s |
| --- | ---: | ---: |
| Original | 7,85 [2,69; 8,13] | 7,84 [4,28; 8,19] |
| Préstamo del array de adjuntos | 19,48 [17,16; 20,27] | 19,13 [17,30; 19,61] |
| Más drenaje acotado del PTY | 53,55 [29,73; 53,79] | 51,52 [13,52; 53,07] |
| Más colores por frame | 60,38 [58,13; 64,28] | 57,46 [55,10; 58,40] |

Se conservan todas las observaciones, incluidas las caídas del original y de
la variante con drenaje. Cuatro rondas permiten comprobar este aumento local,
no prometer un mínimo universal. El equipo mantuvo otros procesos activos.

[Resultados completos](phase1/raw/headless/results.json),
[resumen](phase1/raw/headless/summary.json) y
[hashes de los ejecutables](phase1/raw/builds.json).

## Comportamiento del drenaje

La primera lectura conserva la espera cancelable de `std.Io`. Después se
consulta `poll` con timeout cero y se leen únicamente los datos ya disponibles.
Cada turno queda limitado por el buffer existente de 16 KiB y por ocho lecturas.
No hay un temporizador ni una espera para rellenar el buffer. Un prefijo válido
se entrega aunque después llegue EOF/EIO; la cancelación sigue propagándose.

Los límites pertenecen al actor que lee el PTY. No cambian sus colas, la
propiedad del VT ni las confirmaciones independientes de cada cliente.
`pty_bytes / pty_events` pasa a describir bytes por lote entregado al runtime,
no bytes por syscall.

## Carga más larga y recursos

Tres ejecuciones adicionales, sin profiler, con 64 MiB ASCII y 64 MiB ANSI
por ejecución y la TUI conectada a 111 × 33. ASCII: mediana 57,88 MiB/s,
rango 57,47–60,78. ANSI: mediana 55,46 MiB/s, rango 55,40–57,10.
Las seis mediciones superan 40. No son rondas emparejadas con el original.

El control de recursos usa dos builds `ReleaseFast` con `-Ddiagnostics=true`,
8 MiB por caso y tres segundos de drenaje después de DSR. Sus tiempos no se
mezclan con los resultados principales. Se resta el último snapshot anterior
a la carga del último snapshot en reposo, con el panel todavía vivo.

| Métrica durante la carga | Original | Optimizada |
| --- | ---: | ---: |
| Bytes recibidos del PTY, incluido control | 16.777.312 | 16.777.312 |
| Lotes entregados al runtime | 16.390 | 2.855 |
| Bytes por lote | 1.023,63 | 5.876,47 |
| Frames preparados | 15.828 | 2.748 |
| Bytes de payload de frames | 996.577 | 185.608 |
| Bytes asignados por Telar en la ruta interactiva | 0 | 0 |
| Bytes asignados por el VT en la ruta interactiva | 15.136 | 15.136 |
| Crecimiento de heap retenido | 15.136 B | 15.136 B |
| Pérdidas de observación y resets de historial | 0 | 0 |
| Pérdidas de media, respuestas PTY y entrada | 0 | 0 |

Los bytes de frames corresponden a `CellSync.metrics.frame_bytes`, payloads
codificados; no representan todo el tráfico del socket. Las colas de media e
historial terminan vacías. El máximo observado de media fue dos eventos en
ambos casos, con 3.072 y 16.384 bytes respectivamente; el de historial fue un
evento. El heap final fue 15.034.330 y 15.034.336 bytes. RSS final: 49.119.232 y
45.219.840 bytes. Son snapshots de un control, no una prueba de memoria a largo
plazo ni una garantía de pérdidas nulas con cualquier carga.

[Snapshots, deltas y cargas largas](phase1/raw/followup/summary.json).
Los logs completos conservan también las asignaciones de arranque, media y
observación. Hay muestras posteriores a la carga porque la telemetría omite
ciertos contadores del panel mientras está ingiriendo bytes.

## Siguiente coste para investigar

Se tomó otro perfil de ocho segundos, a una muestra por milisegundo, durante
una carga de 512 MiB ASCII seguida de 512 MiB ANSI. El intervalo de muestreo
queda dentro del ASCII, que duró 10,20 segundos con instrumentación. Es un
perfil diagnóstico separado; sus tiempos no entran en las medianas anteriores.

De las 5.853 muestras del hilo principal, 1.386 pasan por `CellSync.prepare`,
el 23,7 %. Incluyen 744 dentro de `blit` y 366 en `Style.eql`; esas categorías
se solapan y no deben sumarse. Otras 416 pasan por `tcgetpgrp`, el 7,1 %, llamado
al completar salida en `GenericPipeline.handle`.

El control de recursos de 16 MiB termina con 2.750 frames, 2.742 de ellos
`cursor_only_frames`, y 10.068.033 celdas examinadas por el diff, incluido el
arranque. Ese contador significa cero spans de celdas; el frame puede llevar
también scroll o metadatos. El payload de frames suma sólo 193.141 bytes. Este workload repite
líneas: el coste de proyectar y comparar puede ser grande aunque cambien pocas
celdas. No se extrapola esa proporción a salida con contenido único.

La primera hipótesis para la siguiente etapa es reducir preparaciones de
frames obsoletos antes de proyectar y comparar, conservando respuesta inmediata
a entrada, entrega del último frame y las confirmaciones por cliente. Después
conviene revisar la consulta del foreground por cada lote. Son prioridades de
investigación, no una predicción de cuántos MiB/s aportará cada cambio.

El muestreo incluye espera en colas y lecturas de socket. Una pila suspendida
en `readv` no mide el coste del IPC. Los trabajos de observación, media y VT
aparecen en otros hilos y no comparten el denominador del hilo principal.
[Perfil completo](phase1/raw/followup/profile/runtime-sample.txt) y
[conteos con callsites](phase1/raw/followup/profile/summary.json).

## Verificación y reproducción

- 1.271 pruebas pasan y una se omite en backend y contratos públicos del PTY.
- El control del blit anterior con la misma prueba de colores también pasa.
- Formato Zig, codestyle de los cinco archivos y comprobación del diff pasan.
- Todas las ejecuciones aceptadas cierran el runtime, sus hijos y su socket.

La primera ejecución completa tuvo un fallo en la prueba de checkpoints de
agentes, además de dos expectativas incorrectas de las pruebas nuevas que se
corrigieron. El fallo de checkpoints no se reprodujo al repetir la suite final
ni al ejecutar el control original. No se ha determinado su causa.

La comparación usa la fuente original congelada más los cinco archivos de
backend del [parche](phase1/raw/optimization.patch). Conserva los cambios de
GUI que ya tenía ese benchmark. El árbol de trabajo actual también compila
con sus cambios de GUI posteriores, que no forman parte de esta optimización.
Las versiones se identifican en [builds.json](phase1/raw/builds.json). La
[fuente completa validada](phase1/raw/validation/source.patch) se aplica al commit
`bf6e130c9ac81274c405847c6baf20dd3a242382` para reconstruir el checkout de diagnóstico.

Después de corregir las pruebas se reconstruyó el ejecutable. Su hash completo
cambia, pero su sección de instrucciones `__TEXT/__text` es idéntica a la del
candidato medido en las rondas A/B: 5.642.148 bytes, SHA-256
`207d1856fb54254ce4db242ce186b2b39533520c526b3b405cd3531fb6a1dcfa`.
Las cargas de 64 MiB usan esa reconstrucción final.

Los [logs de validación](phase1/raw/validation/results.json) incluyen las órdenes.
Los pasos de pruebas añadidos al build viven sólo en el checkout de diagnóstico:
[parche del build](phase1/raw/diagnostic-build-steps.patch).
Los runners y sus manifiestos quedan junto a cada serie de resultados.

Ejemplo de repetición del caudal conectado:

```sh
zig build -Doptimize=ReleaseFast --prefix /tmp/telar-optimized
python3 tools/terminal_runtime_bench.py \
  --binary /tmp/telar-optimized/bin/telar \
  --output /tmp/telar-throughput-new --mib 64
```

Para repetir el control de recursos, compilar con `-Ddiagnostics=true` y añadir
`--settle-seconds 3`. Cada directorio de salida debe ser nuevo.
