# Ghostty frente a Telar

Informe exploratorio archivado. Las series controladas posteriores y las
conclusiones vigentes están en [README.md](README.md). Los intentos y resultados
de este documento se conservan como registro y no se mezclan con esas series.

Medición local del 18 de septiembre de 2026. Los resultados recogidos sitúan
la mediana de respuesta en unos pocos milisegundos y las colas en decenas de
milisegundos. La comparación sigue siendo exploratoria: el estado de activación
de las ventanas cambió durante el ensayo y la repetición con foco controlado
se interrumpió. No permite afirmar cuánto más rápido es un producto en general.

## Un panel

Seis rondas, 200 muestras medidas y 20 de calentamiento por ejecución. Son
1.200 muestras por aplicación. Ghostty tiene VSync activado y la pantalla
declara una frecuencia máxima de 100 Hz.

| Aplicación | p50 | p95 | p99 | Rango de medianas por ronda |
| --- | ---: | ---: | ---: | ---: |
| Ghostty | 6,90 ms | 18,14 ms | 24,50 ms | 2,23 a 12,60 ms |
| Telar GUI | 2,47 ms | 18,78 ms | 27,77 ms | 2,28 a 8,31 ms |
| Telar TUI dentro de Ghostty | 10,32 ms | 23,97 ms | 33,93 ms | 2,33 a 14,73 ms |

Esta primera serie no registró la activación de la aplicación. El p95 de GUI
pasó de 20,7 a 21,8 ms en las primeras tres rondas a 2,65 a 2,72 ms en las últimas
tres. La mediana agrupada no describe un comportamiento estable.

La media de las diferencias de mediana por ronda, GUI menos Ghostty, fue
-2,18 ms, con intervalo bootstrap del 95% de -4,39 a +0,42 ms. Para la TUI fue
+3,28 ms, con intervalo de +1,14 a +6,15 ms. Son estimaciones de esta serie,
sujetas a posibles diferencias de foco no registradas y a la carga del escritorio.
No son una medición aislada del coste del socket ni una predicción para otra máquina.

[Muestras](raw/single.json), [resumen estadístico](single-summary.md),
[estadísticas completas](single-summary.json) y
[sonda exacta utilizada](raw/single-instrumentation.tar.gz).

## Cuatro splits

Una ronda completa con 100 muestras medidas por aplicación. En ambas
ejecuciones, la aplicación estuvo activa y su ventana tuvo el foco al inicio
y al final de las 120 respuestas, incluido el calentamiento.

| Aplicación | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Ghostty | 9,94 ms | 14,28 ms | 16,80 ms |
| Telar GUI | 3,34 ms | 9,83 ms | 10,21 ms |

Una ronda no basta para estimar la variación entre ejecuciones. Los otros tres
paneles estaban inactivos. La escena tenía 1000 por 700 píxeles; el panel
principal tenía 55 por 35 celdas en Ghostty y 53 por 29 en Telar GUI.
Otra pareja completa quedó excluida: Ghostty estuvo inactivo en las 120
respuestas y Telar GUI activo en las 120. Se conserva en los intentos de layouts.
[Datos de splits](raw/splits-exploratory.json).

## Ensayos pendientes y fallos conservados

Se prepararon casos con cuatro pestañas, cuatro splits con salida continua en
los otros tres paneles, y cuatro pestañas con esa misma carga en las ocultas.
Pasaron pruebas cortas de funcionamiento, pero no se completó la serie repetida.
No se publican percentiles comparativos de esos casos.

Una ejecución de cuatro pestañas de Telar agotó los 75 segundos del fixture
sin resultado final de la sonda. Una repetición posterior se detuvo tras 81
respuestas correctas: durante la espera de la siguiente, la aplicación ya no
estaba activa ni su ventana era principal. Se conservan ambos intentos, sin
mezclar sus series incompletas con las tablas anteriores.

La sonda se reforzó para exigir 500 ms de foco estable antes de medir, y
rechazar una pérdida de foco antes de la entrada, al aceptar su frame o al
agotarse la espera de dos segundos. La primera repetición de un panel abortó
tras 25 respuestas de Ghostty. Otra abortó antes del caudal y registró como
aplicación en primer plano la sesión habitual de Telar, PID 494. Hace falta
mantener libres las ventanas de prueba para completar estas series.

[Intentos de layouts](raw/layout-attempts.json),
[interrupción de un panel](raw/focus-interruption.json) e
[interrupción previa al caudal](raw/throughput-interruption.json).

## Caudal

El fixture escribe 8 MiB de ASCII y 8 MiB con secuencias ANSI, por separado.
Cada tiempo termina con la respuesta DSR posterior al procesamiento del flujo.
Mide ingestión por PTY y emulación con la aplicación funcionando, sin exigir
la presentación de todos los frames. No mide el parser aislado.

Las pruebas cortas dieron 76,8 MiB/s en Ghostty y 8,1 MiB/s en Telar GUI para
ASCII; 89,6 y 8,3 MiB/s para ANSI. Son una observación preliminar por producto,
no un resultado repetido. Además, la auditoría detectó que el handshake podía
arrancar el flujo antes de que la sonda terminase de localizar el marcador,
añadiendo copias de textura completa en lugar de un píxel. No se conoce cuánto
duró ese trabajo adicional. Por ello esos cocientes no son un benchmark
validado. [Datos y logs de las pruebas cortas](raw/throughput-smokes.json).

El runner actual exige marcador localizado y geometría confirmada antes del
handshake. Esa corrección compila, pero queda pendiente de repetir el ensayo
completo sin interrupciones de foco.

La carga usa bloques de 64 KiB y líneas de 64 bytes que no envuelven con los
anchos probados. ANSI se ejecuta después de ASCII, con scrollback ya poblado;
cada carga se compara entre productos, no entre sí. Ambos tienen un límite
predeterminado de scrollback de 10.000.000 bytes.

## Entorno y versiones

Apple M3, 16 GiB de RAM, macOS 26.6.2, build 25G83, conectado a corriente.
Ghostty 1.3.1 estable utiliza su compilación ReleaseFast. Telar se compiló con
Zig 0.16.0 y `-Doptimize=ReleaseFast`, sin trazas de producción.

El binario de Telar procede de una copia aislada de `bf6e130c`, con el parche
de trabajo conservado junto al informe. Las ediciones posteriores del workspace
no forman parte del binario medido. Los manifiestos conservan hashes de los
ejecutables, configuración, sonda y fixture.

[Compilación](build.json), [parche de fuentes](source.patch),
[configuración](config.lua) y [procesos iniciales](raw/processes-before-single.txt).

El escritorio permaneció activo. La captura anterior a la serie registró un
`next-server` de otro proyecto con un 128,8% de CPU. No se detuvo.
Los intervalos describen esta máquina bajo estas condiciones, no un laboratorio
en reposo.

## Frontera de medida

La sonda despacha `keyDown` con `x` al responder nativo del panel principal.
Un proceso Python con la PTY en modo raw alterna el color de una celda. La
medición termina al entrar en el callback de GPU de una operación completada
cuyo píxel contiene el color esperado. Hay una única entrada pendiente.

El tiempo incluye procesamiento de entrada, PTY, emulación, preparación,
GPU y entrega del callback. En Telar incluye runtime y comunicación con el
cliente. En la TUI también incluye el Ghostty que la aloja. No mide teclado
físico, compositor, barrido del monitor ni luz emitida. Tampoco separa el
coste del socket Unix.

Ghostty usa un render target por panel. La sonda identifica la cola Metal que
produce el marcador y descarta las de otros paneles. Telar GUI compone sus
paneles en una escena. El marcador se vuelve a localizar después del setup.
Cada frame aceptado debe tener la secuencia y el color correspondientes.

La sonda añade una lectura de un píxel al trabajo de renderizado. Los caminos
de instrumentación tienen costes distintos: Metal 4 también crea una residencia
y añade una barrera; Ghostty utiliza un blit clásico. El timestamp del callback
incluye su demora de notificación CPU. No son timestamps puros del hardware
ni una medición sin instrumentación.

La implementación de referencia de Ghostty está en
[Metal.zig de v1.3.1](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/renderer/Metal.zig)
y [Frame.zig de v1.3.1](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/renderer/metal/Frame.zig).
Telar utiliza `libghostty-vt` de la revisión `a4edca2a`, identificada por su
dependencia como 1.3.2-dev. Comparten familia de emulador, con revisiones distintas.

## Controles y estadística

- Se descartan 20 respuestas iniciales de cada ejecución. Se conservan todos
  los tiempos posteriores, incluidos los valores extremos.
- Los inputs se programan con pausas deterministas de 25 a 74 ms después de
  confirmar la respuesta anterior. La pausa no entra en el tiempo medido.
- Se alterna el orden de las aplicaciones. Seis rondas con tres variantes
  recorren las seis permutaciones y equilibran las posiciones.
- AeroSpace pone en modo flotante únicamente las ventanas temporales, por
  sus IDs y PID. Se registra su geometría y se rechazan cambios durante la
  medición cuando se solicita un tamaño fijo.
- Ghostty usa una copia privada firmada para cargar la sonda. El runner actual
  lanza directamente su ejecutable; las primeras series usaron LaunchServices.
  Telar usa sockets, historial, datos y configuración aislados por ejecución.
- Un arranque sin ventana y sin ninguna muestra puede reintentarse. Se conserva
  el intento rechazado. Otros fallos detienen la serie.
- No se compila ni se ejecutan otras pruebas de carga durante las series medidas.

La configuración oculta el sidebar de Telar y no carga la configuración del
usuario. Usa JetBrains Mono a tamaño nominal 15. Con la escena de 1000 por
700 píxeles, Ghostty tiene 111 por 35 celdas, Telar GUI 111 por 31 y la TUI
111 por 33. Sus barras y métricas dejan áreas de terminal distintas.

Los splits se crean repetidamente hacia la derecha, con anchos aproximados de
1/2, 1/4, 1/8 y 1/8. Las pestañas mantienen el foco en la primera. Los casos de
carga saturan la salida de los otros tres procesos con texto ASCII. El tiempo
de creación de splits o pestañas no forma parte de la latencia interactiva.

Los percentiles agrupados describen las muestras recogidas. El delta estimado
es la media de las diferencias entre percentiles por ronda. Se remuestrean
rondas emparejadas completas, con semilla fija. Estos intervalos describen la
variación observada, sin corregir confusores como el foco de la primera serie.
El p99 tiene menos precisión que la mediana, especialmente con pocas muestras.

Los campos `host_*` son diagnósticos del proceso instrumentado e incluyen
arranque, setup y calentamiento. No suman todo el árbol de procesos de Telar
y no se utilizan para clasificar CPU o memoria de las aplicaciones.
Asignaciones, bytes de IPC, ocupación de colas, trabajo descartado y memoria
retenida del sistema completo no se han medido. Es una excepción de alcance
a la lista completa de métricas de engineering-invariants.md: este ensayo usa
una sonda externa y los ejecutables no exponen contadores equivalentes de esos
recursos. No permite concluir una mejora de CPU, memoria o eficiencia global.

## Reproducción

Herramientas: [runner](../../../tools/gui_tui_latency.py),
[sonda nativa](../../../tools/gui_tui_latency.m),
[fixture](../../../tools/terminal_bench_fixture.py) y
[resumen estadístico](../../../tools/terminal_bench_report.py).

Se verificaron la compilación de la sonda con Clang, la sintaxis de los tres
scripts Python, el recálculo del resumen y `git diff --check`. La última
corrección del handshake sigue pendiente de validación mediante una ejecución
completa. Se conservan la [instrumentación de splits](raw/layout-instrumentation.tar.gz)
y la [instrumentación actual](raw/current-instrumentation.tar.gz), con sus
[hashes](raw/current-instrumentation-sha256.json).

Ejecutar dejando las ventanas de prueba en primer plano:

```sh
zig build -Doptimize=ReleaseFast --prefix /tmp/telar-release
python3 tools/gui_tui_latency.py /tmp/telar-release/bin/telar /tmp/nueva-serie \
  --mode all --cases single --samples 200 --rounds 6 \
  --viewport 1000 700 --float-windows
python3 tools/terminal_bench_report.py /tmp/nueva-serie/comparison.json \
  --output /tmp/nueva-serie/report

python3 tools/gui_tui_latency.py /tmp/telar-release/bin/telar /tmp/nuevos-layouts \
  --mode native --cases splits tabs splits-load tabs-load --samples 100 --rounds 4 \
  --viewport 1000 700 --float-windows

python3 tools/gui_tui_latency.py /tmp/telar-release/bin/telar /tmp/nuevo-caudal \
  --mode all --cases single --throughput --samples 1 --rounds 6 \
  --viewport 1000 700 --float-windows
```

El último comando usa 20 respuestas de calentamiento y una respuesta medida
para verificar el recorrido posterior al caudal. Esa muestra aislada no se
utiliza como benchmark de latencia.

`--float-windows` requiere AeroSpace y sólo modifica las ventanas temporales.
Sin ese gestor puede omitirse. `--source` identifica el checkout usado para
compilar un binario externo. `--throughput` requiere `--cases single`. En macOS
se necesitan las APIs Metal y Metal 4 utilizadas por la sonda.
