# Investigación del caudal de Telar

La investigación de los 8 MiB/s encontró una copia innecesaria de **2.715.136 bytes
(2,589 MiB)** en el hilo principal, al calcular crédito gráfico incluso con texto sin
imágenes. Evitarla eleva el caudal del control TUI conectado **2,36× en ASCII y 2,25×
en ANSI**, según el cociente de medianas de cuatro rondas. El cambio conserva las
funcionalidades y solo modifica el recorrido del array. Estas mediciones corresponden
al experimento inicial; la [optimización posterior](phase1.md) ya está aplicada al código.

Este diagnóstico complementa el [benchmark comparativo](README.md). Utiliza
el binario original en `ReleaseFast` de [build.json](build.json) y [source.patch](source.patch).
Las referencias de código apuntan al árbol actual; estas rutas coincidían con la fuente congelada.

## Validación A/B

Se ejecutaron 16 pruebas sin perfilador: cuatro variantes por cuatro rondas,
en orden cíclico de cuadrado latino. Cada ejecución procesa 8 MiB ASCII y después
8 MiB ANSI, con PTY interior de 111 × 33. La salida de la TUI se drena por otro PTY;
**no intervienen la GUI nativa ni un renderizador de terminal exterior**.
En los controles desconectados, la TUI termina antes de liberar la carga y el runtime
conserva el panel. El endpoint es recibir DSR, sin exigir presentación visible.

| Variante | ASCII: mediana [mín.; máx.] MiB/s | ANSI: mediana [mín.; máx.] MiB/s |
| --- | ---: | ---: |
| Original, conectado | 8,089 [7,921; 8,128] | 8,112 [7,728; 8,202] |
| Préstamo, conectado | 19,119 [18,107; 19,993] | 18,235 [16,077; 19,193] |
| Original, desconectado | 39,548 [37,075; 41,262] | 37,862 [36,798; 38,303] |
| Préstamo, desconectado | 39,210 [36,551; 41,613] | 35,883 [33,024; 38,602] |

Los [datos](bottleneck/raw/ab-comparison.json) y el [resumen](bottleneck/raw/ab-summary.json)
reproducen la mejora conectada. Las variantes desconectadas tienen rangos solapados: sin adjuntos
no se ejecuta el recorrido afectado. Cuatro rondas no demuestran equivalencia
ni explican todo el coste residual. Los [hashes y builds](bottleneck/raw/builds.json)
identifican ambos ejecutables; el candidato añade únicamente
[este parche](bottleneck/raw/borrow-credit.patch) a la fuente original congelada.
Conectar/desconectar cambia el conjunto de publicación y trabajo del cliente;
esa comparación no aísla solo el render ni el socket.

## Evidencia del perfil y del ejecutable

Se amplió cada carga a 64 MiB para obtener perfiles con `/usr/bin/sample`, a una muestra
por milisegundo. El primer diagnóstico conservaba la barra lateral: PTY interior de
69 × 33. Se repitió a 111 × 33. Ambos tenían PTY exterior de 111 × 35; son diagnósticos
con muestreo, separados de las mediciones de caudal de 8 MiB sin perfilador.

| Perfil | PTY interior | Muestras del hilo principal | En la copia identificada | Fracción |
| --- | --- | ---: | ---: | ---: |
| Exploratorio | 69 × 33 | 5.863 | 2.593 | 44,2 % |
| Geometría fija | 111 × 33 | 5.845 | 2.264 | 38,7 % |

La fracción describe muestras del hilo principal, no CPU total ni ahorro
esperado. Se conservan el [perfil exploratorio](bottleneck/raw/baseline-exploratory-runtime-sample.txt)
y el [perfil con geometría fija](bottleneck/raw/baseline-runtime-sample.txt),
con sus resultados [inicial](bottleneck/raw/baseline-exploratory-result.json)
y [corregido](bottleneck/raw/baseline-result.json). No son rondas del A/B.

La pila identifica `GenericEventDispatcher.handle + 9984` llamando a
`<deduplicated_symbol>`. El ejecutable original, sin desplazamiento de carga, muestra:

```asm
1001c9258: mov   w2, #0x6e00
1001c925c: movk  w2, #0x29, lsl #16
1001c9260: bl    0x10055c520 <_memcpy>
```

El tercer argumento es `0x296e00 = 2.715.136` bytes. El retorno a `0x1001c9264`
corresponde a `+9984`; después se recorren 64 entradas y se llama a `stageNextTransfer`.
El desensamblado [original](bottleneck/raw/baseline-dispatcher-assembly.txt) contiene
esa llamada con ese tamaño; el del [candidato](bottleneck/raw/borrow-dispatcher-assembly.txt) la elimina.

La expresión `for (store.items) |slot|` está en [availableGraphicsCredit](../../../src/backend/runtime/attachment/AttachmentStore.zig#L239).
`items` es un array de 64 adjuntos opcionales: recorrerlo por valor copia todo
a la pila aunque solo haya un panel conectado. El parche recorre
`&store.items` y toma prestado cada adjunto, conservando la suma y las cuotas.

## Por qué afecta a texto sin imágenes

Todo bloque del PTY se encola para media en [GenericPipeline](../../../src/backend/runtime/entrypoints/events/pane/GenericPipeline.zig#L63).
Su [procesador](../../../src/backend/media/Processor.zig#L237) alimenta un
emulador VT separado. La dependencia Ghostty fijada en
[build.zig.zon](../../../build.zig.zon#L25), revisión `a4edca2a`, marca
`kitty_images.dirty = true` cuando una línea provoca scroll al llegar al
borde inferior (`src/terminal/Terminal.zig:2327–2333`), incluso sin imágenes.

Al completar el lote, [GenericMediaCoordinator](../../../src/backend/runtime/entrypoints/events/pane/GenericMediaCoordinator.zig#L59)
actualiza la proyección: [Pane.observeGraphicsDamage](../../../src/backend/pane/Pane.zig#L979)
convierte `dirty` en una nueva revisión. [graphicsCaughtUp](../../../src/backend/runtime/attachment/Attachment.zig#L290)
devuelve falso y
[media_projection.synchronize](../../../src/backend/runtime/entrypoints/events/pane/media_projection.zig#L31)
calcula el crédito antes de intentar preparar una transferencia.

Sin imágenes, `stageNextTransfer` devuelve `idle`. La revisión observada solo avanza al final de
[encodeNextGraphics](../../../src/backend/runtime/attachment/attachment_namespace.zig#L287).
La [entrega al cliente](../../../src/backend/runtime/delivery/Delivery.zig#L601)
también calcula crédito, por lo que existe otra llamada que puede repetir
la copia durante el procesamiento del mismo lote.

Optimizar además las revisiones exigiría conservar las eliminaciones cuando
desaparece la última imagen. El préstamo no altera ese comportamiento.

## Perfil posterior y coste residual

El [perfil del candidato](bottleneck/raw/borrow-runtime-sample.txt) usa cargas de 128 MiB
y muestrea ocho segundos durante ASCII, a 111 × 33 ([resultado](bottleneck/raw/borrow-result.json)).
Desaparece la copia dominante. Una rama `handleIngested → pump → CellSync.prepare`
concentra 1.378 de 5.919 muestras del hilo principal (23,3 %), principalmente render,
blit y comparación de celdas. Eso localiza trabajo restante; no cuantifica el ahorro
de otra optimización. Los distintos tamaños de carga impiden comparar estos caudales
perfilados como si fueran el A/B.

La publicación se limita por ACK e ingesta en curso en
[Attachment.prepareNextCells](../../../src/backend/runtime/attachment/Attachment.zig#L154), sin reloj de 60 Hz aquí.
[CellSync.prepare](../../../src/backend/runtime/attachment/CellSync.zig#L232)
puede ejecutar render, proyección y diff en el hilo principal. El cliente
[confirma las celdas al aplicarlas](../../../src/client/application/panes/ApplyPaneFrameHandler.zig#L17),
antes de entregar recursos a la presentación. Por tanto, las publicaciones
pueden superar la frecuencia de los frames visibles. El perfil muestra coste
en esa ruta, pero aún no aísla cuánto caudal recuperaría cambiar su cadencia.

El [observador de historial](../../../src/backend/history/Observer.zig#L285) reproduce
los bytes en un tercer VT y ejecuta [heurísticas](../../../src/backend/history/Observer.zig#L228)
por lote. `history.Sample.signal` aparece en los workers: prueba trabajo adicional,
sin demostrar que sea el límite residual. Desactivar la captura persistente de salida
no equivale a desactivar ese observador.

No se encontró una cuota explícita de 8 MiB/s. Las lecturas se acotan a
[16 KiB](../../../src/backend/pane/pane_namespace.zig#L46) y la [siguiente](../../../src/backend/runtime/entrypoints/events/pane/GenericIngestCoordinator.zig#L62)
se programa al completar la ingesta. El trabajo por lote y por el hilo principal
puede reducir el caudal, sin establecer por sí solo una tasa fija.

## Reproducción y validación

El [runner](../../../tools/terminal_runtime_bench.py) reutiliza DSR; se conserva [la versión usada](bottleneck/raw/terminal_runtime_bench.py).
Desde la raíz, con los dos builds preparados y directorios de salida nuevos:

```sh
python3 tools/terminal_runtime_bench.py --binary /tmp/tgb-release/bin/telar --output /tmp/base-attached --mib 8
python3 tools/terminal_runtime_bench.py --binary /tmp/tgb-credit-borrow/bin/telar --output /tmp/borrow-attached --mib 8
```

Añadir `--detach` y otra salida reproduce cada control desconectado. Repetir cuatro
rondas rotando el orden registrado. `--sample --mib 128` reproduce el perfil posterior.
El [manifiesto](bottleneck/raw/manifest.json) registra las herramientas y configuración.

Pasaron 103/103 pruebas existentes de crédito, gráficos y adjuntos, 44/44 pasos de build,
con `zig build test-credit-diagnostic -Doptimize=ReleaseFast --summary all` en el árbol
experimental. Se conservan el [paso temporal de pruebas](bottleneck/raw/diagnostic-test-step.patch)
y la [validación](bottleneck/raw/validation.json). El parche permanece experimental, sin aplicarse a `src/`.

No se midieron bytes de IPC, asignaciones, colas/pérdidas de observación, memoria total
ni latencia interactiva del candidato. No se presupone que conserve las mismas pérdidas
de observación al aumentar el caudal. Esta prueba no valida una publicación general;
el coste residual sigue sin atribuirse a una causa única.
