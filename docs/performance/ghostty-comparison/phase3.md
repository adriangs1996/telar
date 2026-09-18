# Tercera mejora: adelantar la respuesta al input

La GUI de macOS reduce la latencia bajo carga mediante una gracia de dibujo asociada al panel que recibió entrada. En cuatro parejas, el p95 por ronda baja **3,21 ms en splits**, IC95% **[-4,08; -2,02]**, y **5,09 ms en pestañas**, IC95% **[-6,46; -2,96]**. Un panel no muestra una diferencia concluyente. Son resultados del recorrido `keyDown` hasta el callback GPU del marcador verificado, no de presentación física.

La GUI cumple el criterio de conservación del caudal en los cuatro casos de 64 MiB, con un margen práctico de pérdida del 5%. La ráfaga original de GUI de 8 MiB deja ASCII variable inconcluso. Por ese motivo se fija y ejecuta una confirmación independiente de ocho pares y 64 MiB por payload, sin mezclar ni sustituir las observaciones originales. La TUI sostenida también deja ANSI variable inconcluso; una conclusión sobre GUI no resuelve ese resultado.

## Latencia

400 muestras útiles por versión y caso; 20 warmup por ejecución. Cuatro rondas AB, BA, AB, BA. Viewport 1000×700, PTY 111×31 en panel único y pestañas, 53×29 en el panel principal de los splits. Cada uno de los otros tres productores solicita 1 MiB/s. Baseline = binario estable de fase 2; candidato = esta mejora.

| Caso | Versión | p50 | p95 | p99 | Máximo |
| --- | --- | ---: | ---: | ---: | ---: |
| Un panel | Fase 2 | 7,82 ms | 22,57 ms | 27,44 ms | 30,71 ms |
| Un panel | Fase 3 | 8,03 ms | 21,70 ms | 26,84 ms | 29,21 ms |
| Cuatro splits, tres con carga | Fase 2 | 19,87 ms | 33,11 ms | 39,01 ms | 50,22 ms |
| Cuatro splits, tres con carga | Fase 3 | 15,80 ms | 30,63 ms | 37,61 ms | 40,82 ms |
| Cuatro pestañas, tres con carga | Fase 2 | 7,60 ms | 23,70 ms | 30,92 ms | 32,28 ms |
| Cuatro pestañas, tres con carga | Fase 3 | 7,04 ms | 19,89 ms | 26,03 ms | 31,59 ms |

Los siguientes intervalos remuestrean parejas completas, no muestras individuales. Por eso los deltas por ronda no equivalen a restar los percentiles agrupados.

| Caso | Delta p50 e IC95% | Delta p95 e IC95% |
| --- | ---: | ---: |
| Un panel | 0,05 [-0,83; 1,27] ms | -0,32 [-2,91; 2,26] ms |
| Cuatro splits, tres con carga | -4,17 [-5,94; -2,28] ms | -3,21 [-4,08; -2,02] ms |
| Cuatro pestañas, tres con carga | -0,27 [-1,50; 0,96] ms | -5,09 [-6,46; -2,96] ms |

Los cuatro deltas de p95 son negativos tanto en splits como en pestañas. Los p99 son descriptivos. La inferencia usa 10.000 remuestreos, semilla 20260918; con cuatro pares la cobertura es limitada y no hay corrección por comparaciones múltiples.

Se conservan nueve intervalos fuera de la tolerancia en 998 intervalos completos, repartidos entre tres corridas: splits baseline r0, pestañas candidato r1 y pestañas baseline r3. Sus mínimos respectivos son 0,7058, 0,8211 y 0,8348 MiB/s. Las ventanas de aproximadamente 500 ms no están sincronizadas con las muestras de eco; no permiten afirmar una carga idéntica en esos intervalos. Todas las muestras entran en el análisis principal.

La latencia de las series de caudal con una única muestra útil por corrida queda excluida. Los analizadores v2 marcan esos datos como acompañamiento del caudal y suprimen las etiquetas inferenciales de latencia que producía la primera versión.

## Caudal con GUI

Cada fila es un estrato independiente. R es la media geométrica de los cocientes candidato/baseline; L95 es su límite inferior unilateral del 95%. La regla operativa exige L95 ≥ 0,95 en cada estrato. Que un intervalo incluya 1 no demuestra equivalencia. El endpoint es escritura al PTY hasta respuesta DSR.

### Ráfagas originales de 8 MiB, cuatro parejas

| Corpus | Contenido | Fase 2, mediana [mín.; máx.] | Fase 3, mediana [mín.; máx.] | R | L95 | Resultado |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Variable | ASCII | 82,56 [76,16; 83,97] | 79,76 [74,52; 83,21] | 0,9754 | 0,9325 | Inconcluso |
| Variable | ANSI | 71,77 [44,37; 75,85] | 72,66 [70,43; 76,95] | 1,1336 | 0,9983 | Cumple margen |
| Repetido | ASCII | 80,20 [56,39; 82,15] | 79,61 [75,41; 84,44] | 1,0787 | 0,9568 | Cumple margen |
| Repetido | ANSI | 74,60 [68,56; 77,74] | 72,52 [65,82; 77,67] | 0,9761 | 0,9572 | Cumple margen |

Tasas en MiB/s.

### Confirmación independiente de 64 MiB, ocho parejas

| Corpus | Contenido | Fase 2, mediana [mín.; máx.] | Fase 3, mediana [mín.; máx.] | R | L95 | Resultado |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Variable | ASCII | 77,42 [60,40; 83,16] | 81,17 [74,67; 83,80] | 1,0941 | 1,0267 | Cumple margen |
| Variable | ANSI | 71,32 [56,67; 74,03] | 71,43 [67,92; 75,61] | 1,0547 | 0,9922 | Cumple margen |
| Repetido | ASCII | 79,18 [71,58; 85,12] | 84,22 [75,42; 86,02] | 1,0497 | 1,0046 | Cumple margen |
| Repetido | ANSI | 72,67 [58,90; 76,24] | 75,73 [68,46; 76,91] | 1,0420 | 0,9905 | Cumple margen |

Tasas en MiB/s.

El tamaño de ocho pares de la extensión se fijó después de observar la variabilidad de las ráfagas cortas y antes de comenzar cualquier corrida larga de GUI. No se modificó el margen ni se añadieron rondas según el resultado. La extensión usa copias privadas de las herramientas: sólo cambian el tamaño del corpus y sus validaciones; la sonda nativa y los binarios son los mismos. El corpus variable se genera y se calcula su hash antes del cronómetro.

## TUI sostenida

Cuatro parejas por corpus, 64 MiB ASCII y 64 MiB ANSI. La salida anfitriona se drena por un PTY; no se compara directamente su tasa con la GUI.

| Corpus / contenido | Fase 2 | Fase 3 | R | L95 | Resultado |
| --- | ---: | ---: | ---: | ---: | --- |
| repeat/ansi | 70,24 | 75,93 | 1,10 | 1,02 | Cumple margen |
| repeat/ascii | 72,42 | 86,07 | 1,19 | 1,09 | Cumple margen |
| variable/ansi | 75,83 | 72,39 | 0,99 | 0,94 | Inconcluso |
| variable/ascii | 75,52 | 82,60 | 1,10 | 0,97 | Cumple margen |

Las 16 corridas completan los payloads y cierran runtime e hijos correctamente. ANSI variable no permite descartar una pérdida superior al margen. No se repite esa serie hasta obtener un resultado favorable.

## Implementación y límites

`pane_inputs.record` notifica al port de presentación después de admitir bytes dirigidos a un child. `FramePacer`, propiedad de `NativeLoop`, conserva el ID del panel, la generación de su attachment y el frame aplicado en ese momento. Sólo una revisión posterior de ese mismo panel visible puede adelantar el dibujo, durante un máximo de 30 ms y hasta 16 frames adelantados. La tabla tiene capacidad fija de 64 entradas y no asigna memoria. Reutiliza `core.Pacer`; no añade mensajes IPC.

`TelarView.drawDelay` consulta esta política antes de pedir el drawable. Una consulta no consume créditos; se registra sólo un token de preparación válido y los frames capturados en su commit. Los frames adelantados reanclan la cadencia en el instante actual, sin acumular deuda futura. La salida ordinaria conserva la cadencia de 60 Hz y un único frame GPU en vuelo. Los ACK de celdas siguen confirmando aplicación al modelo, antes de la entrega GPU. Linux conserva su frame clock actual.

La gracia es una heurística acotada: salida concurrente del panel también puede producir un frame posterior al input. No identifica causalmente el eco. El presupuesto se destruye con la conexión GUI y las generaciones impiden transferirlo a otro attachment. [Contrato y pruebas del recorrido](../../flows/host-input-to-screen.md#native-input-and-drawing-cadence).

## Diagnóstico de la espera restante

La sonda opcional `TGB_DRAW_DIAGNOSTICS=1` enlaza intento, drawable, preparación, commit y callback GPU de la misma submission únicamente cuando verifica el marcador esperado. Los snapshots anteriores del view no identifican qué panel los provocó; `model_dirty_ms` permanece sin atribución. Hay almacenamiento acotado y ningún log por evento. Las cifras principales se midieron con ese diagnóstico apagado.

En el diagnóstico aislado del candidato, obtener un drawable tarda p50 4,058 ms y p95 15,276 ms; 18 de 30 adquisiciones superan 1 ms. El intento del frame verificado llega a p50 1,444 ms desde la entrada. Son datos exploratorios, con dos productores que incumplen parcialmente la carga, y no sustituyen el A/B principal. `nextDrawable` se ejecuta en el hilo de la ventana y puede bloquearlo; ésa es la siguiente espera concreta que conviene abordar.

Una opción pendiente es recibir drawables mediante `CAMetalDisplayLink`, conservar sólo el modelo más reciente y mantener un frame GPU en vuelo. Necesita su propio A/B: cambiar el momento de adquisición puede afectar también la latencia de un panel en reposo. No se ha aplicado en esta fase.

## Validación y reproducción

- 942 tests del cliente y 689 de GUI pasan en el árbol aislado medido, incluidos 18 tests nuevos de pacing e integración.
- La prueba nativa de ventana, GPU, input y cierre termina con cero fallos.
- Pasan estilo y límites de módulos; el checker incluye sus 19 tests. El workspace completo también compila.
- La fuente medida conserva el GUI congelado usado en fase 2. Las ediciones concurrentes ajenas quedan fuera del candidato y no se incluyen en este cambio.
- Todas las series se ejecutan serialmente, sin builds, tests ni perfiles simultáneos. Un `next-server` ajeno permanece activo; los snapshots de procesos se conservan.

El [análisis principal](phase3/analysis.json), [análisis GUI largo](phase3/long-analysis.json), [TUI sostenida](phase3/sustained-analysis.json) y [procedencia de los binarios](phase3/source-provenance.json) incluyen cifras sin redondear. Los [protocolos originales](phase3/protocol.md) y [de la extensión](phase3/long-protocol.md) fijan orden, tamaños, criterios y fallos.

El [archivo de evidencia](phase3/evidence.tar.gz) conserva corridas, warmup, recibos, focos, tamaños y hashes de los payloads, cierres, herramientas, analizadores originales y v2, patches de fuentes, logs de compilación y pruebas, exploraciones y diagnósticos. Incluye `sha256.json` para cada fichero. [Hash y alcance del archivo](phase3/evidence.json). Se omiten bundles privados, binarios, sockets y bases de datos sintéticas del fixture.

Para recalcular, extraer el archivo y pasar `final/variable` y `final/repeat` al analizador v2; usar el analizador largo v2 para `long/variable` y `long/repeat`. Los hashes identifican exactamente los ejecutables medidos. No se vuelven a medir Ghostty ni el coste aislado del socket Unix en esta fase.
