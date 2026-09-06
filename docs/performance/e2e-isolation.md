# Resultado de las optimizaciones end to end

Las seis áreas están implementadas en `perf/e2e-isolation`, worktree `/Users/adriangonzalez/sandbox/telar-perf-e2e`. El código termina en `d5f377d`; la base es `4708085`. Los cambios locales del worktree original quedaron intactos.

Hay mejoras medidas en búsqueda, consultas obsoletas, transferencia gráfica y respuesta con el terminal bloqueado. **No certifico ausencia de regresiones generales.** El eco sin carga y dos microbenchmarks de SHM empeoran en sus agregados locales, con dispersión demasiado alta para emitir el veredicto que exige el proyecto. El gate nativo de Ubuntu sigue pendiente.

## Resultados principales

Cinco repeticiones pareadas, alternando el orden. Los tiempos siguientes son la mediana de los cinco p50 emitidos por cada prueba de mecanismo, con 20 muestras por repetición. No son percentiles de latencia interactiva.

| Área | Base | Candidato | Qué quedó comprobado |
| --- | ---: | ---: | --- |
| Framing chunked hacia TLS | 23 escrituras | 6 escrituras | Los mismos 279 bytes, incluidos CRLF y trailer |
| Staging RGBA 4K en runtime | 2.254 µs | 0,667 µs | Mayor llamada de staging por imagen, incluyendo solicitud y adopción; la copia ocurre en media |
| Compresión RGBA 512 × 256 en presentación | 1.578 µs | 58 µs | El trabajo de deflate sale del caller; el resultado se infla a los mismos píxeles |
| Búsqueda completa | 1.416 µs | 404 µs | Patrón ausente con prefijo repetido, 1.000 filas de 128 columnas |
| Mayor turno de búsqueda | 1.416 µs | 14,8 µs | 32 filas por turno, sin prestar el VT a otro hilo |
| Ráfaga de historial | 32 consultas SQLite, 1.262 µs | 1 consulta, 186 µs | Se conserva una respuesta correlacionada por petición y el resultado de la última |
| Muestreo del host | 100 llamadas inline y 100 pumps | 0 llamadas inline, 1 trabajo pendiente y 0 pumps | Prueba con efectos controlados; no es una medición de syscalls del sistema operativo |

Mover trabajo no elimina su coste. Preparar la imagen 4K completa consume aproximadamente 2,25 ms en ambas versiones. La compresión completa pasa de 1,578 a 1,621 ms en este fixture. La mejora está en cuánto ocupa el hilo que atiende input, no en presentar esos costes como desaparecidos.

Las pruebas de mecanismos ejecutan la preparación y la compresión de forma controlada. Separan las llamadas del runtime o presenter del trabajo delegado. Las pruebas end to end siguientes sí usan los actores de producción.

### Terminal lento y gráficos completos

- Con el lector del PTY del host detenido, la base no reenvía ninguna de las 32 teclas inyectadas. El candidato reenvía las 32 en las cinco repeticiones. Después de reanudar la lectura, ambas versiones han reenviado las 32. La observación usa contadores periódicos del runtime, no un cronómetro por tecla.
- Una imagen RGBA de 3.840 × 2.160 llega completa al host sintético en **2.153 ms frente a 1.924 ms**, medianas de cinco ejecuciones. Reducción local del 10,7%.
- Las diez transferencias conservan los 33.177.600 bytes de píxeles. SHA-256: `70c15061f349462f423106aff19bb9287f861015a216bdd9314f86e77dc8169e`.
- Ambas versiones envían un payload comprimido de 4.004.011 bytes. El verificador reensambla APC, decodifica base64 e infla zlib. No se obtuvo la mejora enviando menos píxeles.
- Este host consume bytes y valida imágenes. No mide pintado físico ni reproduce toda la implementación de Ghostty o Kitty.

### Eco interactivo

200 muestras por ejecución, separación de 50 ms. Cada celda es la mediana de cinco percentiles calculados por ejecución, en microsegundos.

| Carga | Versión | p50 | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| Un pane | Base | 235,81 | 739,01 | 1.400,76 |
| Un pane | Candidato | 255,25 | 828,28 | 996,01 |
| Dos floods | Base | 574,54 | 905,59 | 1.128,11 |
| Dos floods | Candidato | 553,79 | 916,18 | 1.141,30 |

Cero timeouts en las 4.000 muestras. No llamo a esto una mejora demostrada del eco. Sin carga, p50 sube 8,2% y p95 sube 12,1%; bajo flood, p50 baja 3,6% y p95/p99 suben aproximadamente 1,2%.

La dispersión impide extrapolar esos agregados. Por ejemplo, los p50 sin carga van de 214,81 a 523,46 µs en la base y de 216,17 a 466,88 µs en el candidato. El máximo p99 por ejecución bajo flood alcanza 4.407,93 µs en el candidato. Los resultados completos están conservados, incluidos los desfavorables.

Las primeras pruebas con una tarea de salida por cada frame motivaron una corrección adicional. El cliente ahora intenta **una sola escritura no bloqueante de hasta 4 KiB**. Si no cabe todo, entrega exclusivamente el resto al actor. No espera espacio en el terminal desde el hilo de input. Hay tests para escritura parcial, descriptor lleno, orden de bytes y ACK.

### Microbenchmarks existentes

Se repararon las llamadas a APIs obsoletas y el grafo Lua de `zig build bench`. Base y candidato recibieron las mismas reparaciones de compatibilidad.

Los 34 casos conservan `payload_bytes_per_op`. Sus p95/p99 siguen siendo percentiles de medias de lotes, no de eventos individuales.

La última serie incluye aumentos del 8,0% en publicación SHM 4K y del 9,0% en ingestión SHM 4K. La amplitud entre las cinco medianas de publicación equivale al 40,8% de su mediana en la base y al 29,7% en el candidato. En ingestión, al 19,7% y 25,8%. No los declaro aprobados ni atribuyo una causa que no medí.

## Qué cambió

1. **Framing HTTP.** `relayLine` escribe cada línea completa. Conserva el prefijo consumido ante EOF y el límite de longitud. El cuerpo sigue avanzando por fragmentos; no espera a reunir un evento SSE. La reducción comprobada es de llamadas a la escritura TLS. No se ejecutó un benchmark de red HTTPS.
2. **Preparación gráfica en runtime.** Una cola de ocho solicitudes deduplicadas guarda claves y resultados con reserva de cuota. Media prepara SHM o copia; el attachment adopta. Detach y generaciones desaparecidas liberan resultados y reservas. No se comparte un nombre SHM consumible entre varios consumidores.
3. **Salida y compresión del cliente.** Dos buffers acotados, un envío pendiente y ACK después de completar sus bytes. POSIX usa una descripción independiente y no bloqueante del terminal para el intento de 4 KiB. El resto se escribe desde el actor, sin otro escritor activo. La compresión tiene un trabajo pendiente y como máximo 512 KiB de entrada copiada. Eliminar una imagen no destruye un trabajo todavía prestado. Windows conserva el actor sin fast path.
4. **Scrollback.** Un matcher KMP reutilizado por la API síncrona y el flujo incremental. Conserva smart-case ASCII, coordenadas y matches no solapados. La búsqueda admite hasta 10.000 filas y 512 columnas, comprueba la revisión y tiene un deadline de 250 ms. Si cambia el terminal, devuelve un fallo reintentable en lugar de mezclar versiones. Buscar mientras hay output continuo puede requerir reintento.
5. **Historial.** La outbox sustituye consultas de primera página aún no enviadas. El worker descarta consultas superadas dentro de un lote de hasta 64 peticiones. Escrituras y otras operaciones son barreras de orden. No combina páginas, snapshots, consultas de detalle ni peticiones CLI que cierran tras responder.
6. **Métricas del host.** Un actor recibe el sampler por valor. Mientras está pendiente, los ticks no crean más trabajo. El runtime publica la copia completa y solo bombea clientes si cambia la revisión visible. Se registran duración y edad de la muestra. El test de 100 ticks demuestra admisión y publicación, no una mejora cuantificada de latencia bajo un procfs lento.

El precio de memoria es visible. En el escenario de eco, el heap instrumentado del cliente pasa de unos 13,7 MB a 16,0 MB. Los buffers de salida pueden crecer hasta 16 MiB cada uno según geometría. Después del warmup no aumentan `heap_allocs` ni `interactive_allocs` en ese escenario. Esto no equivale a contar todo `malloc` del proceso.

## Apagado y pruebas

También se corrigió el apagado que impedía repeticiones limpias. Se termina el grupo foreground seleccionado por el PTY, se descarta I/O pendiente y se conserva abierto el master hasta finalizar sus préstamos. No atribuyo el bloqueo original a una causa concreta del kernel.

En la serie final, el candidato sale y retira el socket en **20/20** ejecuciones. Bajo flood tarda aproximadamente entre 42 y 47 ms. La base queda viva más de cinco segundos en las diez ejecuciones con flood, aunque acepta `server stop`.

El comando ahora anuncia `telar runtime is stopping`, no una salida que todavía no ha ocurrido. El runner comprueba daemon, procesos de las sesiones aisladas y socket. La limpieza de las 40 ejecuciones terminó; no quedaron runtimes aislados vivos al verificar el cierre.

Validación local:

- `zig build test --summary all`: **3.478/3.478 tests**.
- `zig build test -Doptimize=ReleaseFast --summary all`: **3.478/3.478 tests**.
- Build de producción `ReleaseFast` con diagnósticos: correcto.
- Cinco repeticiones pareadas de los 34 microbenchmarks y de las pruebas de mecanismos.
- Cinco repeticiones pareadas de eco, flood, host bloqueado y roundtrip 4K.

Máquina verificada: Apple M3, arm64, macOS 26.6.2, Zig 0.16.0. No se ejecutó el [gate oficial](../performance-gates.md) en Ubuntu 24.04 x86_64 nativo. Un intento de cross-build se detuvo por falta de `libsqlite3` para Linux; no valida ese destino. Tampoco se hizo soak prolongado, RTT remoto ni carga de una base grande de historial.

## Evidencia y reproducción

- [Resumen estructurado](e2e-isolation/summary.json).
- [Muestras individuales y resultados end to end](e2e-isolation/raw/e2e-results.json).
- [Serie previa al fast path](e2e-isolation/raw/e2e-before-fast-output-results.json).
- [Logs y pruebas](e2e-isolation/raw/).
- [Hashes de los artefactos](e2e-isolation/sha256.json).
- [Parche de instrumentación de la base](e2e-isolation/baseline-instrumentation.patch). Solo repara benchmarks y añade pruebas; no aplica las optimizaciones al runtime de referencia.

Desde este worktree, con sus dependencias ya disponibles:

```sh
CANDIDATE="$PWD"
BASE=$(mktemp -d /tmp/telar-base.XXXXXX)
RESULTS=$(mktemp -d /tmp/telar-perf.XXXXXX)
git archive 4708085 | tar -x -C "$BASE"
(cd "$BASE" && patch -p1 < "$CANDIDATE/docs/performance/e2e-isolation/baseline-instrumentation.patch")
cp -R zig-pkg "$BASE/zig-pkg"
(cd "$BASE" && zig build -Doptimize=ReleaseFast -Ddiagnostics=true --prefix "$RESULTS/base")
zig build -Doptimize=ReleaseFast -Ddiagnostics=true --prefix "$RESULTS/candidate"

# Warm compilation caches before collecting paired measurements.
(cd "$BASE" && zig build bench -- --samples 3 --sample-ms 20 --json)
zig build bench -- --samples 3 --sample-ms 20 --json
(cd "$BASE" && zig build test-isolation test-compression-isolation -Doptimize=ReleaseFast)
zig build test-isolation test-compression-isolation -Doptimize=ReleaseFast

PYTHONDONTWRITEBYTECODE=1 python3 tools/perf_suite.py \
  --baseline-source "$BASE" --candidate-source "$CANDIDATE" \
  --baseline "$RESULTS/base/bin/telar" \
  --candidate "$RESULTS/candidate/bin/telar" \
  --output "$RESULTS/measurements" --repetitions 5
```

Los resultados originales permanecen también en `/tmp/telar-perf-e2e/final`. Las mediciones finales usan `e2e-fast-output`; las anteriores documentan la iteración y no se mezclan con sus percentiles.
