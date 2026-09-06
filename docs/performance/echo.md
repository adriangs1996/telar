# Latencia de eco: VT inline acotado

Informe del 6 de septiembre de 2026. Rama `perf/echo`, separada del checkout de
trabajo original. Base `8b5c864`; implementación medida `50818f8`.
La entrega `366b3f0` añade formato y corrige un fixture de tests, sin cambiar
el código ejecutable de producción medido.

El cambio reduce el p50 en las cinco parejas de cada escenario medido. No queda
aprobado como mejora sin regresiones: persisten resultados adversos en p99 y falta
el gate nativo de Ubuntu. Tampoco se ha demostrado un mínimo teórico ni agotado
las posibilidades de optimización.

## Qué queda implementado

`Pane.canInlineOutput` admite entre 1 y 32 bytes ASCII imprimibles, con parser y
decodificador UTF-8 en estado ground. Exige `status_display == .main`, fila residente,
celdas narrow con codepoints y estilo coincidente, sin hyperlinks, inserción,
wrap pendiente ni desplazamiento de charset temporal. No escribe el margen
derecho. Los demás casos siguen pasando por el actor de VT.

Ghostty sigue interpretando los bytes. El dispatcher conserva el préstamo de VT,
guarda el resultado inline y lo entrega al mismo coordinator después de retornar
del pipeline. No encola una completion adicional ni publica un VT a medio cambiar.
No cambia el protocolo, las cuotas ni el ACK posterior a entrega real al host.

Las pruebas cubren admisión, wrapping, estilos, hyperlinks, graphemes, wide cells,
continuaciones CSI/OSC/Kitty/UTF-8 y mil ejecuciones con asignaciones desactivadas.
El gate de ingestión usado por las pruebas sigue obligando al camino actor.

Código: [pane/root.zig](../../src/backend/pane/root.zig),
[pane/pipeline.zig](../../src/backend/runtime/application/event_dispatcher/pane/pipeline.zig).
Contrato: [host-input-to-screen](../flows/host-input-to-screen.md).

## Resultados finales

Apple M3, Mac15,3, 8 CPU lógicas, 16 GiB; macOS 26.6.2, build 25G83, arm64;
Zig 0.16.0. ReleaseFast, diagnósticos y tracer desactivados para esta tabla.

Valores en **µs: mediana de cinco percentiles calculados por ejecución**.
No son percentiles de muestras agrupadas. La última columna es el cambio de
esas medianas; un número negativo significa menor latencia.

| Escenario | Base p50 / p95 / p99 | VT inline p50 / p95 / p99 | Cambio p50 / p95 / p99 |
|---|---:|---:|---:|
| Eco del kernel, pausa 50 ms | 253,020 / 666,400 / 788,213 | 235,354 / 673,893 / 820,943 | −6,98% / +1,12% / +4,15% |
| Eco del kernel, continuo | 66,084 / 103,093 / 118,802 | 58,625 / 98,141 / 120,025 | −11,29% / −4,80% / +1,03% |
| Aplicación raw, pausa 50 ms | 264,333 / 710,226 / 795,056 | 248,396 / 704,991 / 934,201 | −6,03% / −0,74% / **+17,50%** |
| Aplicación raw, continua | 70,688 / 117,184 / 141,713 | 62,062 / 105,592 / 122,606 | −12,20% / −9,89% / −13,48% |
| Dos floods, pausa 50 ms | 505,062 / 749,109 / 853,111 | 418,500 / 652,669 / 806,050 | −17,14% / −12,87% / −5,52% |

También calculé el cambio **dentro de cada pareja** y después su mediana. No es
la misma operación y no debe confundirse con la última columna anterior:

| Escenario | Mediana de cambios pareados p50 / p95 / p99 |
|---|---:|
| Eco, pausa | −7,03% / +1,62% / +2,27% |
| Eco, continuo | −11,29% / −23,35% / −12,42% |
| Aplicación, pausa | −5,96% / +0,23% / +6,33% |
| Aplicación, continua | −12,98% / −20,76% / −13,91% |
| Dos floods | −16,94% / −13,36% / −8,68% |

La diferencia entre ambas agregaciones importa. Por ejemplo, los cambios p99
pareados del eco continuo fueron +53,47%, −18,29%, −34,52%, +58,41% y −12,42%.
En aplicación con pausa fueron −10,07%, +6,33%, −2,32%, +23,07% y +30,55%.
No hay base para declarar las colas de latencia resueltas.

El rango entre ejecuciones dividido por la mediana del p50 fue:
9,99% / 7,25% para eco con pausa y 4,16% / 4,62% para eco continuo,
base / candidato respectivamente. Se conservan todas las repeticiones y sus
muestras, no solo la agregación favorable.

### Método y alcance de la medida

- Pantalla virtual de 160 × 40. Veinte pares de calentamiento después de dos
  segundos de drenaje; 200 muestras por ejecución con pausa y 500 sin pausa.
- Base y candidato adyacentes; orden AB, BA, AB, BA, AB. Los controles de topología
  tienen su propia rotación, independiente del orden de la pareja.
- Un único estímulo `~` pendiente. El oráculo Ghostty debe observar un codepoint
  visible adicional y synchronized-output desactivado. Después se envía DEL y
  se comprueba el borrado antes de emitir otra muestra.
- El timestamp final corresponde a la llegada del fragmento que deja al oráculo
  en ese estado, antes de procesarlo en VT. Esto excluye ese procesamiento del
  cronómetro, pero no su influencia sobre el ritmo del fixture. No mide dibujo
  físico, teclado, GPU ni scanout. Tampoco observa cada commit intermedio dentro
  de un mismo fragmento de lectura.
- Los fixtures sin flood recibieron una mediana de 45 bytes por eco en ambas
  versiones. Bajo flood, 613 frente a 598: la lectura puede incluir actualizaciones
  de otros panes. La carga y el estímulo son iguales, no el instante de cada
  actualización de fondo.
- El flood reutiliza `load_latency.FLOOD_COMMAND`: dos productores `seq` en bucle,
  un pane inicial inactivo y el pane de eco enfocado. Son cuatro panes visibles.
  La medida usa el oráculo VT, no búsqueda de la tecla en bytes de escape.

Son **16.000 muestras finales completadas**, sin timeout de eco o borrado.
Las 50 ejecuciones cerraron cliente, runtime e
hijos, quitaron el socket y no necesitaron limpieza forzada del cliente.

La serie final de eco con pausa se obtuvo durante la ablación `vt-only`.
Su ejecutable y el compilado desde el código final tienen todas las secciones
`__TEXT` idénticas, incluidas código y constantes. Los hashes completos difieren;
se registran ambos, no se presentan como un mismo archivo.

## Suelo empírico y distancia restante

Los controles son un PTY directo, un relay de un proceso y un relay de dos
procesos conectado por socketpair. Usan el mismo estímulo y oráculo. El eco raw
incluye una aplicación que lee y escribe; el eco del kernel no necesita que la
aplicación procese la tecla.

Estos controles se midieron en una serie separada, con cinco repeticiones y las
mismas dimensiones, muestras y pausas. Los binarios y opciones están registrados.
Los tiempos de Telar de aquella serie incluían el `ioctl` posteriormente retirado;
**solo sus controles se usan aquí como referencia**.

| Fixture | PTY directo p50 | Un proceso p50 | Dos procesos p50 | Telar final p50 |
|---|---:|---:|---:|---:|
| Kernel, pausa 50 ms | 26,646 | 58,104 | 79,541 | 235,354 |
| Kernel, continuo | 3,208 | 15,146 | 21,500 | 58,625 |
| Aplicación, pausa 50 ms | 46,438 | 69,229 | 94,438 | 248,396 |
| Aplicación, continua | 11,208 | 20,791 | 27,208 | 62,062 |

En continuo, Telar queda **37,125 µs y 2,73×** por encima del p50 del relay de dos
procesos. Con aplicación, la diferencia es 34,854 µs, unas 2,28×.
No interpreto las diferencias entre controles con pausa como costes aditivos:
el coste de despertar y la dispersión cambian mucho respecto al modo continuo.

Esto no demuestra un límite teórico. El relay omite emulación, framing de Telar,
diff, metadatos, historial, créditos, ACK y aislamiento frente a clientes lentos.
No sería un reemplazo correcto de Telar. Y un mínimo observado demuestra un tiempo
alcanzado, no que sea imposible bajar de él.

Para asignar una cota teórica en µs habría que fijar CPU, kernel, scheduler,
protocolo y condiciones de carga. El camino causal conserva trabajo obligatorio:
entrada del host, cliente → runtime, PTY/aplicación, VT, runtime → cliente,
composición/diff y salida al host. Quitar esperas de cola no elimina ese trabajo.
Este estudio mide referencias alcanzables en un fixture; no prueba optimalidad
ni permite tratar los 37 µs restantes como ahorro íntegramente recuperable.

## Qué explica el cambio

Cinco trazas pareadas por modo, 100 ecos continuos o 200 con pausa por ejecución.
Se verificaron dos dumps por ejecución, footer y cero eventos descartados.
Los pares de borrado y calentamiento no se mezclan con los ecos.

Mediana de cinco p50 por fase, en µs. La envolvente se calcula por evento antes
de obtener percentiles; no es la suma de las medianas de las tres filas.

| Fase, continuo | Base | VT inline |
|---|---:|---:|
| VT queued → start | 6,125 | 0,167 |
| VT start → done | 0,292 | 0,292 |
| VT done → ingest dispatch | 4,104 | 0,042 |
| Envolvente completa de VT | 10,479 | 0,500 |
| Host read → host flush done | 82,708 | 73,542 |

Con pausa, la envolvente de VT pasó de 20,042 a 2,562 µs. El mecanismo confirmado
es evitar el despacho al actor y su completion para el caso admitido. En continuo,
el tiempo de ingestión propiamente dicho quedó igual en esta agregación.

El tracer cambia los tiempos: registra reloj y reserva atómica en un buffer fijo
de 16.384 eventos por proceso, y estos builds llevan diagnósticos. No uso sus
percentiles como resultado de producción. La correlación por orden solo sirve
para este fixture de un pane y una tecla pendiente, no para tráfico general.
Las tablas completas y las duraciones individuales están en los archivos de fases.

## Experimentos retirados y errores de medición

### Consulta de foreground por ioctl

Darwin libc hace una comprobación `isatty` antes de `TIOCGPGRP`. Se probó consultar
el PTY conocido directamente, conservando la consulta actual al kernel, sin caché.
En cinco series de cuarenta lotes alternados de 10.000 consultas se ahorraron unos
0,18 µs por operación, cerca del 7%. Son medias de lotes, no latencias individuales.

La mejora del microbenchmark no justificó el cambio end to end:

- Inline VT más ioctl, serie AB/BA: mediana de cambios pareados de eco con pausa
  +3,90% en p50 y +17,96% en p99. Las cinco parejas empeoraron en ambos percentiles.
- Solo ioctl, contra la base: +0,55% / +7,28% / +13,26% pareados.
- Solo VT: −7,03% / +1,62% / +2,27% pareados.

Se retiró el ioctl de producción. No se atribuye su resultado a un mecanismo
particular del scheduler: esa causa no quedó aislada. El probe conserva ambas
consultas como experimento reproducible. `tcgetpgrp` sigue en producción.

Referencia de fuente: Apple Libc, commit
`71bbe350ab79eef58113991d817ccc6165061a64`,
[`termios.c`](https://github.com/apple-oss-distributions/Libc/blob/71bbe350ab79eef58113991d817ccc6165061a64/gen/FreeBSD/termios.c)
y [`isatty.c`](https://github.com/apple-oss-distributions/Libc/blob/71bbe350ab79eef58113991d817ccc6165061a64/gen/FreeBSD/isatty.c).

### IPC con MSG_DONTWAIT

Se probó un envío inline de hasta 4 KiB, con progreso reanudable y fallback al
actor. El test con socket lleno quedó bloqueado dentro de `send`.

El repro aislado de Python confirmó en esta máquina que `send` y `sendmsg` con
`MSG_DONTWAIT | MSG_NOSIGNAL` excedían dos segundos sin terminar. Un descriptor
puesto en modo no bloqueante devolvió would-block después de 60 envíos de 68 bytes.
No se extrapola esto a otros kernels. Tampoco se cambian los flags compartidos
con el lector de producción para hacer pasar el benchmark.

El experimento se retiró. Se conserva el snapshot de los cinco archivos de IPC,
con contexto de instrumentación; no es un parche autónomo recomendado para aplicar.
El repro acotado está en `tools/socket_pressure.py`.

### Orden del benchmark y apagado

El primer runner rotaba toda la lista y después la invertía. Con solo dos
binarios, ambas operaciones se cancelaban y la base quedaba siempre primero.
Se corrigió, se añadió un test y se repitieron las series con parejas adyacentes
AB/BA. Las series anteriores permanecen como exploratorias, no como validación.

También se corrigió el desmontaje del fixture: detach es Ctrl+B, d, y hay que
seguir drenando el PTY durante la restauración del terminal. El stack observado
mostraba `tcsetattr`/`ioctl`, no una lectura nativa bloqueada.

Un timeout externo interrumpió una serie de host bloqueado después de siete
registros completos. El runtime restante se detuvo y se verificó la limpieza
antes de repetir los diez registros. La serie incompleta no es la validación final.

## Seguridad, corrección y gate pendiente

- Debug y ReleaseFast: **82/82 pasos, 3.487/3.487 tests** en cada modo.
- Herramientas de eco: cinco tests Python aprobados.
- Una repetición ReleaseFast falló en el test de descripciones de agentes:
  esperaba `invalid_output` y recibió `failed`. Sus comandos podían cerrar stdin
  antes de consumir el prompt. Un repro con 50 ms de demora del padre produjo
  BrokenPipe con el fixture anterior y ninguna excepción al drenar la entrada.
  Corregí solo los fixtures y repetí ambas suites, incluyendo la seed fallida
  `0x8d3cf5e0`. El fallo y el repro permanecen en la evidencia.
- Host bloqueado, cinco repeticiones por versión: **32/32 entradas reenviadas
  mientras el host no drenaba**, en ambas versiones. Los diez apagados completos
  quitaron runtime, hijos y socket. La base ya incluía el aislamiento anterior.
- El parche de instrumentación de la base se aplicó a un archive limpio y se
  compiló. Todas sus secciones `__TEXT` coinciden con el tracer base medido.
- Los [gates](../performance-gates.md) permiten 5% / 8% / 10% en p50 / p95 / p99;
  superar esos límites de dispersión exige repetir en un host tranquilo.
- No se ejecutó el gate oficial Ubuntu 24.04 x86_64 nativo. El intento anterior
  de cross-build completo carecía de sqlite3 para Linux. Los checks de compilación
  de la suite no sustituyen ese gate.
- El p99 de aplicación con pausa empeora un 17,50% al comparar las medianas de
  percentiles. La dispersión y los cambios de signo impiden aprobar el resto de
  colas como libres de regresión. Debe repetirse en el host oficial y localizar
  las fases tardías antes de mergear.
- No se midieron presentación física, RTT remoto, varios clientes, soak largo,
  historial grande, tráfico HTTPS real ni las tres noches consecutivas exigidas
  para una release.

No se ha mergeado esta rama ni modificado el checkout original.

## Evidencia y reproducción

[Resumen con repeticiones y hashes](echo/summary.json).
`echo/raw/final/` contiene las series finales, trazas, muestras y diagnósticos.
`echo/raw/experiments/` y `echo/raw/exploratory/` conservan también los resultados
adversos, incompletos o sustituidos. Los archivos grandes están comprimidos con
gzip; no se eliminaron muestras para comprimirlos. `echo/sha256.json` cubre la
evidencia versionada. Los ejecutables no se incluyen; sus hashes sí.

```sh
cd /path/to/telar-perf-e2e
BASE=$(mktemp -d /tmp/te-base.XXXXXX)
git archive 8b5c864 | tar -x -C "$BASE"
cp -R zig-pkg "$BASE/zig-pkg"
(cd "$BASE" && zig build -Doptimize=ReleaseFast -Ddiagnostics=false \
  --prefix /tmp/te/base)
zig build -Doptimize=ReleaseFast -Ddiagnostics=false --prefix /tmp/te/candidate
zig build echo-probe -Doptimize=ReleaseFast --prefix /tmp/te/probe
python3 tools/echo_path.py \
  --probe /tmp/te/probe/bin/echo-probe \
  --baseline /tmp/te/base/bin/telar --candidate /tmp/te/candidate/bin/telar \
  --output /tmp/te/echo --samples 200 --repetitions 5 --controls
```

Continuo: `--gap 0 --samples 500`. Aplicación: añadir `--application`.
Flood: añadir `--floods 2`, manteniendo `--controls` sin nombres. Para incluir los
tres controles nativos en los escenarios sin flood, quitar `--controls`.
Cada ejecución necesita un directorio de salida nuevo; mantener cortos los sockets.

Para reproducir la base trazada, aplicar
[`baseline-tracing.patch`](echo/baseline-tracing.patch) al archive limpio antes
del build. Compilar ambas versiones con `-Ddiagnostics=true -Decho-trace=true`;
usar `--trace --controls`, como máximo 200 muestras, sin floods.
`tools/echo_trace.py DIRECTORY` analiza un directorio de una ejecución.
Descomprimir primero los `.echo.jsonl.gz` si se usan las trazas versionadas.

```sh
python3 -m unittest discover -s tools -p test_echo_tools.py
python3 tools/socket_pressure.py
/tmp/te/probe/bin/echo-probe foreground
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
```
