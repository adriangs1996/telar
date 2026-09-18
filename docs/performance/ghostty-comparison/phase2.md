# Segunda mejora: agrupar antes de proyectar

La GUI alcanza **84,81 MiB/s ASCII y 78,59 MiB/s ANSI** con texto repetido. Con texto variable, las medianas son **79,15 y 72,53 MiB/s**. El cambio agrupa las publicaciones antes de proyectar el VT y calcular el diff; la preparación de celdas deja de dominar el trabajo observado en el hilo principal.

**Hay una regresión de latencia bajo carga.** En splits, la diferencia media de p95 entre rondas es **+3,82 ms**, IC95% **[+0,94; +6,41]**; en pestañas es **+1,89 ms**, IC95% **[+0,19; +3,40]**. Se conserva la mejora como un avance de caudal con ese coste pendiente de resolver. No se da por alcanzado un mínimo general de 80 MiB/s ni por igualado Ghostty en todos los casos.

## Caudal con GUI

Cuatro rondas por corpus, 8 MiB ASCII y 8 MiB ANSI por ejecución. Son medianas y rangos en MiB/s; el endpoint es la respuesta DSR posterior al payload, no presentación en pantalla. La fase 1 se vuelve a medir en las mismas parejas.

| Corpus | Versión | ASCII, mediana [mín.; máx.] | ANSI, mediana [mín.; máx.] |
| --- | --- | ---: | ---: |
| Repetido | Telar fase 1 | 65,75 [59,60; 67,50] | 56,84 [52,58; 61,07] |
| Repetido | Telar nuevo | 84,81 [83,36; 85,56] | 78,59 [71,95; 78,91] |
| Repetido | Ghostty | 78,97 [68,72; 88,07] | 86,82 [58,94; 89,47] |
| Variable | Telar fase 1 | 55,79 [55,49; 68,32] | 48,95 [33,48; 52,03] |
| Variable | Telar nuevo | 79,15 [68,00; 85,48] | 72,53 [70,07; 76,72] |
| Variable | Ghostty | 85,61 [84,53; 94,23] | 92,28 [83,26; 94,93] |

El candidato supera 80 MiB/s en las cuatro rondas de ASCII repetido y en dos de ASCII variable. Ninguna de las ocho rondas ANSI alcanza 80. Frente a fase 1, mejora ambos casos en las cuatro parejas de cada corpus. Ghostty es un control orientativo: la ventana mide lo mismo, pero su PTY tiene 111×35 celdas frente a 111×31 en Telar. No se atribuye la diferencia al socket Unix.

[Serie repetida](phase2/raw/final/repeat/summary.json), [serie variable](phase2/raw/final/variable/summary.json) y sus [rondas individuales](phase2/raw/final/variable/runs.json).

## Latencia de entrada

La serie variable tiene 400 muestras útiles por versión y caso, con otras 20 de calentamiento por corrida. La latencia va de `keyDown` al callback GPU que verifica el píxel cambiado. Los fondos apuntan a 1 MiB/s por panel.

| Caso | Versión | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| Un panel | Fase 1 | 5,94 ms | 16,18 ms | 18,95 ms |
| Un panel | Nueva | 5,96 ms | 16,86 ms | 23,25 ms |
| Cuatro splits, tres escribiendo | Fase 1 | 17,58 ms | 26,70 ms | 31,89 ms |
| Cuatro splits, tres escribiendo | Nueva | 20,30 ms | 30,76 ms | 35,20 ms |
| Cuatro pestañas, tres ocultas escribiendo | Fase 1 | 5,81 ms | 14,97 ms | 19,71 ms |
| Cuatro pestañas, tres ocultas escribiendo | Nueva | 6,31 ms | 16,94 ms | 19,68 ms |

Los percentiles anteriores agrupan muestras. La inferencia siguiente calcula el percentil por corrida y empareja rondas completas; por ello no coincide con restar los percentiles agrupados. Delta = candidato menos fase 1.

| Caso | Delta p50, IC95% | Delta p95, IC95% |
| --- | ---: | ---: |
| Un panel | -0,03 [-0,58; 0,53] ms | 0,86 [-2,12; 3,15] ms |
| Splits con carga | 2,51 [1,00; 4,01] ms | 3,82 [0,94; 6,41] ms |
| Pestañas con carga | 0,47 [0,14; 0,70] ms | 1,89 [0,19; 3,40] ms |

El aumento de p50 en splits aparece en las cuatro parejas. Una ventana del segundo ensayo del candidato baja a 0,9491 MiB/s, por debajo del mínimo prefijado de 0,95; se conservan su carga observada y todas sus latencias. Los otros quince ensayos de Telar con carga cumplen las ventanas verificadas. Esto limita la afirmación de trabajo idéntico, pero no justifica descartar la regresión. El mecanismo concreto del aumento de latencia todavía no está aislado.

En la serie repetida, con 160 muestras útiles por aplicación, el p95 agrupado pasa de 16,49 a 16,94 ms y p99 de 19,53 a 27,53 ms. El delta emparejado de p95 es +0,55 ms, IC95% [−0,21; +1,38]; no demuestra equivalencia. Todos los extremos y máximos se conservan.

[Deltas por ronda e intervalos](phase2/raw/final/variable/paired.json), [incumplimiento de carga](phase2/raw/final/variable/rate-misses.json), [auditoría repetida](phase2/raw/final/repeat/summary-audit.json) y [auditoría variable](phase2/raw/final/variable/summary-audit.json).

## Implementación

Cada adjunto de cliente admite trabajo antes de la proyección y el diff. Reutiliza `core.Pacer`: cuatro créditos para ráfagas y una cadencia de 60 Hz en salida sostenida. La entrada admitida abre una gracia acotada de 30 ms y 16 frames para su panel. Los snapshots y EOF evitan la espera por cadencia; la ingestión y los ACK conservan su orden. Una proyección sin cambios también consume crédito, porque ya hizo el trabajo.

Un temporizador global despierta el runtime si hay publicación pendiente. Conserva el plazo armado durante esperas temporales por ingestión o ACK y sólo lo sustituye por uno anterior. Al completar vuelve a consultar los propietarios actuales. No retiene punteros a paneles o adjuntos; el cierre une sus actores antes de destruir la aplicación. El último frame pendiente llega aunque el proceso deje de escribir.

El Pacer y el temporizador pasan a `telar-core` para compartir sus implementaciones sin dependencias entre backend y frontend. Sus instancias siguen perteneciendo a cada proceso. La emulación canónica, el historial, la observación y los gráficos permanecen activos. [Contrato del recorrido](../../flows/host-input-to-screen.md).

## Carga sostenida y recursos

Tres parejas AB/BA/AB por corpus, 64 MiB ASCII y 64 MiB ANSI por corrida, sin profiler. TUI sobre PTY exterior drenado: 111×33 celdas interiores, sin renderizador exterior. Estas cifras no se mezclan con las de GUI.

| Corpus | Versión | ASCII, mediana [mín.; máx.] | ANSI, mediana [mín.; máx.] |
| --- | --- | ---: | ---: |
| Repetido | Fase 1 | 59,87 [58,25; 61,95] | 57,29 [56,60; 57,63] |
| Repetido | Nueva | 89,25 [87,19; 90,46] | 73,68 [70,25; 75,00] |
| Variable | Fase 1 | 53,82 [52,75; 54,36] | 51,61 [50,73; 52,25] |
| Variable | Nueva | 84,51 [83,17; 85,09] | 73,50 [72,88; 76,83] |

El control de recursos usa builds separados con diagnósticos, 8 MiB por caso y tres segundos de espera posterior. Las cuatro ventanas del mismo PID procesan 16.777.312 bytes PTY, incluido control.

| Patrón y versión | Frames preparados | Bytes de frames | Celdas examinadas por diff |
| --- | ---: | ---: | ---: |
| Repetido, fase 1 | 2.568 | 174.448 | 9.407.028 |
| Repetido, nueva | 18 | 13.468 | 65.934 |
| Variable, fase 1 | 2.825 | 10.899.048 | 10.348.197 |
| Variable, nueva | 27 | 97.712 | 97.125 |

El heap instrumentado crece 15.136 bytes en las dos cargas del candidato. No aumenta el contador clasificado como `interactive_telar_alloc_bytes`; sí hay reservas o crecimientos atribuidos a VT y media según el evento en curso. Las tareas de `std.Io.Threaded` usan un allocator externo a estos contadores: el timer añade un worker lógico y hasta dos esperas hijas, con asignaciones de sus registros. Esta excepción acotada queda documentada junto al scheduling; **no se afirma cero asignaciones del proceso**.

El baseline variable registra un reset de observación y `history_input_dropped += 9`. Ese contador incluye lotes de salida y control; no equivale a nueve teclas perdidas. Los otros tres diagnósticos no incrementan los contadores de descarte consultados, y las colas publicadas terminan vacías. El RSS final del candidato es 44.810.240 bytes en ambos controles; son snapshots, no picos ni una prueba de memoria a largo plazo.

[Diagnósticos y cargas largas](phase2/raw/final/followup/summary.json); [auditoría detallada de recursos](phase2/resources.md).

## Perfil y siguiente trabajo

En el perfil final, sólo 8 de las 5.920 muestras del hilo principal pasan por `CellSync.prepare` (0,14%). El control anterior a esta mejora tenía 1.386 de 5.853 (23,68%); son perfiles con ventanas distintas, no una estimación exacta de CPU ahorrada. Los contadores de frames y diff confirman la reducción de trabajo.

El primer candidato cancelaba y reconstruía demasiadas esperas: sus workers acumulaban 704 muestras `_sigtramp`, 655 bajo hijos del timer. Con el plazo estable pasan a una. Son muestras, no número de llamadas. La regresión de latencia de los layouts persiste pese a ese ajuste.

Antes de otra mejora de caudal, el siguiente paso es localizar el tramo de latencia añadido en splits y pestañas. Para el caudal restante, el perfil señala las consultas de foreground (`tcgetpgrp`: 454 muestras del main y otra consulta en observación), las heurísticas de agentes por lote y el parsing adicional de media. Cualquier reutilización debe conservar la identidad y el momento de la observación, y la semántica de cursor/scroll de los gráficos. Son candidatos a investigar, no ganancias prometidas.

El 82,03% de muestras del main en espera futex no demuestra un cuello en IPC. El perfil incluye hashing/idle inicial y parte de ASCII; no incluye ANSI. [Análisis y límites del perfil](phase2/profile.md).

## Validación

- Compilan el binario aislado de comparación y el workspace en `ReleaseFast`.
- Suites backend, PTY, frontend, cliente, pacing y timer: **2.844 pasan, uno omitido y uno falla**. El fallo de checkpoint de agentes (`ProviderFailed`) se reproduce en el binario de fase 1; no se declara verde la suite completa.
- Pasan nueve contratos nuevos de publicación, tres nuevos de temporizador y siete tests de las herramientas. Pasan los límites entre módulos, el formato y la comprobación de whitespace del código.
- El ensayo real de último frame verifica tres ciclos de salida, marcador final y silencio, sin entrada. El marcador llega en 8,60–10,05 ms, permanece estable y el runtime termina sin hijos supervivientes ni limpieza forzada. Es una prueba funcional con límite de 250 ms, no un benchmark de latencia.
- Las 40 corridas GUI finales completan sin rechazos de arranque. Hay 3.280 muestras útiles y 800 de calentamiento; se conserva el único incumplimiento de carga.

[Tests y builds](phase2/raw/validation/tests-stable.log), [fallo reproducido en fase 1](phase2/raw/validation/test-direct-phase1.log), [herramientas](phase2/raw/validation/tools-final.log), [último frame y cierre](phase2/raw/final-frame/candidate-stable/result.json).

## Metodología

La comparación principal empareja Telar GUI de fase 1 con el candidato v2. Ghostty actúa como control independiente en `single`. El protocolo final fija cuatro rondas, alternando fase 1 → v2 y v2 → fase 1. Ghostty se ejecuta antes de la pareja en las rondas pares y después en las impares.

| Corpus | Casos | Muestras por corrida, tras calentamiento | Control Ghostty |
| --- | --- | ---: | --- |
| Repetido | `single` | 40 | Sí |
| Variable | `single`, `splits-load`, `tabs-load` | 100 | Sólo `single` |

Cada corrida descarta las primeras 20 muestras. Los casos con carga usan cuatro panes o pestañas: uno responde a la entrada y tres producen texto, con un objetivo de **1 MiB/s por productor**. El foco vuelve al primero antes de medir. La sonda exige aplicación activa y ventana principal con foco; registra ambas condiciones al iniciar la entrada y al aceptar su respuesta.

La latencia comienza con la inyección de `keyDown` nativo y termina en el callback que confirma una operación de GPU con el píxel del marcador esperado. No es una medición de presentación física. El render target se fija en 1000×700 píxeles, con escala 1. En `single`, el PTY de Telar es 111×31 celdas y el de Ghostty 111×35. El control Ghostty mantiene VSync activado. La geometría se contrasta entre versiones y rondas dentro de cada modo.

El caudal se mide antes de la latencia de `single`: 8 MiB ASCII y 8 MiB ANSI, desde el inicio de la escritura hasta recibir la respuesta DSR posterior. El runtime de Telar responde al DSR; este endpoint no necesita esperar a que el cliente presente el contenido. El corpus y su SHA-256 se preparan antes del cronómetro. Se rechaza un cambio de geometría durante el caso.

Los percentiles agrupados describen las muestras conservadas. Para inferencia se emparejan las rondas: se calcula la media de sus diferencias de p50 y p95, con bootstrap de 10.000 remuestreos de rondas, semilla 20260918 e intervalo percentil del 95%. No se tratan las muestras de una misma corrida como rondas independientes. El p99 es descriptivo. Los intervalos son exploratorios y no corrigen por comparaciones múltiples.

Los binarios proceden de una copia aislada del código. Los archivos GUI de esa copia coinciden con la instantánea inicial, incluidas entrada y selección de foco; las ediciones concurrentes de esos archivos en el workspace quedan fuera de la comparación. Cada ejecución archiva hashes de binarios, herramientas, configuración y sonda nativa.

## Límites

Las aplicaciones ajenas al ensayo siguieron activas. Un snapshot durante la serie repetida registró `next-server` con más de un núcleo de CPU ocupado; no permite atribuirle una muestra concreta. No se descartaron las rondas más lentas.

- El limitador regula escrituras por productor y descarta crédito atrasado tras una pausa. `rate_met` comprueba medias entre checkpoints completos, separados por al menos 0,5 s, con tolerancia de ±5%. No demuestra caudal instantáneo idéntico.
- Esas ventanas no coinciden con los límites de las muestras GPU. Se excluyen los fragmentos anteriores al primer checkpoint y posteriores al último. Una escritura final interrumpida puede quedar fuera de los checkpoints y de `max_write_ms`. Este último mide tiempo de pared e incluye posible desprogramación; no identifica por sí solo bloqueo del PTY.
- Con `--record-rate-misses`, un incumplimiento de caudal conserva todas las latencias y `rate_met=false`, sin reintento ni cambio de tolerancia. Las conclusiones de esas ventanas deben referirse al objetivo y al caudal observado, sin afirmar carga idéntica. Los demás errores de validación siguen deteniendo la serie.
- El texto variable deriva de hashes hexadecimales deterministas. Conserva líneas de 64 bytes; ANSI usa un SGR gris fijo. En los fondos, el corpus de 8 MiB se recorre cíclicamente, aproximadamente cada ocho segundos al caudal objetivo. No representa Unicode, gráficos ni variedad de estilos, ni implica texto globalmente único durante toda la ejecución.
- Ghostty y Telar tienen distinta geometría en celdas e instrumentación GPU diferente. Sus diferencias no aíslan el coste del socket Unix. DSR tampoco demuestra que todos los estados intermedios hayan sido presentados; el coalescing puede sustituirlos.
- Cuatro rondas limitan la precisión de los intervalos, especialmente en las colas. Un intervalo que incluya cero no establece equivalencia ni una cota de no regresión. La latencia de `single` se observa después del caudal, no como una prueba independiente de arranque en frío.
- Los diagnósticos de asignaciones cubren los contadores instrumentados; excluyen tareas de `std.Io` y allocators de bibliotecas no instrumentados. No permiten afirmar ausencia total de asignaciones. Los máximos muestreados de RSS y colas tampoco garantizan sus picos reales; `frame_bytes` no es el tráfico total del socket.

## Intentos exploratorios conservados

La serie variable de v1 quedó incompleta y fue sustituida por v2. Conserva 24 corridas aceptadas, con 2 incumplimientos de caudal en `splits-load` del candidato. La corrida 25 conserva sus 100 respuestas medidas, pero falló la comparación de geometría entre rondas: un fondo de Ghostty pasó de 111×35 a 111×36. El pane principal y el render target permanecieron iguales. Esa corrida se guarda por separado y no completa la comparación. El registro está en [partial-summary.json](phase2/raw/exploratory-v1/variable/partial-summary.json); v1 y v2 no se mezclan.

Un control inicial de entrega del último frame comparó `monotonic_ns()` entre procesos con Python 3.9 en macOS, cuyos orígenes no eran compartidos. Sus timeouts se conservan como resultados de un test inválido, no como evidencia de pérdida del frame. La versión corregida usa `clock_gettime_ns(CLOCK_MONOTONIC_RAW)` con un origen común. Los controles corregidos de fase 1, v1 y v2 constan como correctos. Son pruebas funcionales de entrega, retención durante reposo y cierre, no el benchmark de latencia GPU.

## Reproducibilidad

El runner archivado es [native-final.py](phase2/raw/scripts/native-final.py). Reutiliza `probe.dylib`, `config.lua` y la copia privada `GhosttyProbe.app` de `/tmp/tgb-phase1-setup`; no modifica la aplicación instalada. Los siguientes comandos reproducen el protocolo y requieren directorios de salida nuevos:

```sh
python3 docs/performance/ghostty-comparison/phase2/raw/scripts/native-final.py \
  --baseline /tmp/tgb-phase1-final-verified/bin/telar \
  --candidate /tmp/tgb-phase2-stable/bin/telar \
  --setup-dir /tmp/tgb-phase1-setup --tools tools \
  --output /tmp/tgb-repro-repeat --rounds 4 --samples 40 \
  --cases single --text-pattern repeat --ghostty-control

python3 docs/performance/ghostty-comparison/phase2/raw/scripts/native-final.py \
  --baseline /tmp/tgb-phase1-final-verified/bin/telar \
  --candidate /tmp/tgb-phase2-stable/bin/telar \
  --setup-dir /tmp/tgb-phase1-setup --tools tools \
  --output /tmp/tgb-repro-variable --rounds 4 --samples 100 \
  --cases single splits-load tabs-load --text-pattern variable \
  --background-mib-per-second 1 --record-rate-misses --ghostty-control
```

`--ghostty-control` sólo añade Ghostty a `single`, también en el segundo comando. El manifiesto registra la configuración y los hashes efectivos. `runs.json` y los resultados por corrida conservan las muestras; `paired.json` y `summary.json` las resumen; los checkpoints, fallos de caudal, logs y archivos de cierre permiten revisar la calidad. Sólo se reintenta un arranque sin ventana, sin panes y sin observaciones de tiempo. Deben verificarse `complete.json`, cobertura de rondas y hashes antes de presentar una serie como completa.

Para reconstruir el código medido, aplicar [measured-source.patch](phase2/raw/validation/measured-source.patch) sobre `bf6e130c9ac81274c405847c6baf20dd3a242382` en una copia aislada y ejecutar `zig build -Doptimize=ReleaseFast --prefix /tmp/tgb-rebuilt`. El patch incluye los cambios de fase 1, la GUI congelada y los pasos de tests diagnósticos. Para el build instrumentado, añadir `-Ddiagnostics=true`. La fase 1 conserva su propia [procedencia](phase1.md).

[Hashes de ejecutables y fuente](phase2/raw/validation/source-provenance.json) y [manifiesto del archivo](phase2/raw/archive-manifest.json). El binario del workspace también compila, pero no se mezcla con el medido: contiene las ediciones GUI concurrentes del usuario. Después de compilar sólo se añadió un comentario de asignaciones al código de producción; el resto de los cambios posteriores son documentación y evidencia. Las apps, ejecutables, bases de datos, sockets, certificados y caches no se archivan.

El cambio del timer entre el candidato exploratorio v1 y el final se conserva en [timer-stability.patch](phase2/timer-stability.patch). Se verificó que puede aplicarse a la inversa sobre la fuente medida; permite inspeccionar esa diferencia sin mezclar sus resultados.
