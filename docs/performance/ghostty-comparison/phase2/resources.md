# Auditoría de recursos

Los cuatro diagnósticos finales confirman una reducción de publicaciones y trabajo de diff. No justifican afirmar «cero asignaciones» ni «cero pérdidas» para ambas versiones. Los datos corresponden a una corrida por variante y patrón, con ASCII y ANSI de 8 MiB cada uno y tres segundos de espera posterior.

Se verificó `summary.json` contra las líneas originales, incluida cada resta numérica. Ventanas del mismo PID:

| Patrón y variante | PID | Líneas inicial/final | Uptime inicial/final, ms |
|---|---:|---:|---:|
| repeat, fase 1 | 48762 | 3 / 6 | 3028 / 6048 |
| repeat, candidato estable | 48922 | 2 / 5 | 2006 / 5013 |
| variable, fase 1 | 49465 | 3 / 6 | 3016 / 6039 |
| variable, candidato estable | 49108 | 3 / 6 | 3020 / 6037 |

Las fuentes están en `/tmp/tgb-p2-stable-followup/raw/diagnostic-{pattern}-{variant}/runtime.sock.runtime-{pid}.log`. Las cuatro ventanas acumulan **16.777.312 bytes PTY**: 16 MiB de corpus más 96 bytes de control. Las cifras siguientes son deltas entre esas muestras, no totales desde el arranque.

| Patrón y variante | Lotes PTY | Frames | Bytes de frames de celdas | Celdas examinadas por diff |
|---|---:|---:|---:|---:|
| repeat, fase 1 | 2637 | 2568 | 174448 | 9407028 |
| repeat, candidato | 3099 | 18 | 13468 | 65934 |
| variable, fase 1 | 3131 | 2825 | 10899048 | 10348197 |
| variable, candidato | 3074 | 27 | 97712 | 97125 |

`frame_bytes` mide frames de celdas codificados, no todos los bytes del socket ni la salida del terminal anfitrión. La menor cantidad de `folded_pty_events` del candidato tampoco significa menor agrupación: ese contador sólo observa lecturas mientras ya existe un frame pendiente de ACK, no todos los eventos agrupados antes de preparar el frame.

| Patrón y variante | Allocaciones registradas / bytes acumulados | Interactive VT, allocs / bytes | Media, allocs / bytes | Observation, allocs / bytes | Crecimiento neto del heap vivo |
|---|---:|---:|---:|---:|---:|
| repeat, fase 1 | 33 / 15136 | 33 / 15136 | 0 / 0 | 0 / 0 | 15136 B |
| repeat, candidato | 33 / 15136 | 2 / 9628 | 31 / 5508 | 0 / 0 | 15136 B |
| variable, fase 1 | 34 / 16600 | 33 / 15136 | 0 / 0 | 1 / 1464 | 14436 B |
| variable, candidato | 33 / 15136 | 33 / 14632 | 0 / 504 | 0 / 0 | 15136 B |

`interactive_telar_allocs` e `interactive_telar_alloc_bytes` no crecen en ninguna ventana. Esto sólo describe el allocator instrumentado y la clasificación de ruta vigente; no contabiliza todas las asignaciones del proceso, las tareas de `std.Io` ni otras bibliotecas.

La diferencia de atribución es compatible con el código de contabilidad, sin demostrar por sí sola qué objeto concreto se reservó:

- [Heap.zig:61](../../../../src/core/Heap.zig#L61) asigna cada reserva al `current_path` del hilo. Sólo la etiqueta como `interactive_vt` cuando coinciden ruta interactiva y guardia de terminal.
- [Heap.zig:75](../../../../src/core/Heap.zig#L75) carga un crecimiento de `resize`/`remap` a la ruta actual y aumenta bytes, sin incrementar el número de reservas. Por eso **0 allocs y 504 bytes en media es un resultado válido**, no una inconsistencia del resumen.
- [Runtime.zig:109](../../../../src/backend/runtime/Runtime.zig#L109) mantiene la ruta del evento durante su despacho; [event.zig:79](../../../../src/backend/runtime/event.zig#L79) clasifica `pane_media` como media. [GenericMediaCoordinator.zig:70](../../../../src/backend/runtime/entrypoints/events/pane/GenericMediaCoordinator.zig#L70) llama al pump de clientes bajo esa ruta. El render que ese pump provoque puede quedar atribuido a media. Estos contadores no permiten equiparar «media» con contenido gráfico ni declarar idéntica atribución entre versiones.

El baseline variable registra **`history_input_dropped += 9` y `history_observation_resets += 1`**. Los otros tres diagnósticos no muestran crecimiento de esos campos. Los demás contadores publicados de descarte consultados quedan en cero en las cuatro ventanas.

El nombre `history_input_dropped` no significa nueve teclas perdidas: [telemetry.zig:79](../../../../src/backend/runtime/observability/telemetry.zig#L79) publica `history_observer.dropped_events`, que también recibe salida y eventos de control. [Observer.zig:329](../../../../src/backend/history/Observer.zig#L329) cuenta el batch activo más el evento entrante, limpia el batch y solicita un reset; si el entrante cabe, `prepareBytes` lo vuelve a admitir. Por tanto, el nueve es el contador de esa política, no una medición exacta de nueve eventos definitivamente descartados, comandos o caracteres. Sí hay evidencia de descarte/reset de observación en ese baseline. No hay evidencia aquí de pérdida en el flujo canónico de PTY: `pane_input_dropped_bytes` y `pty_response_dropped` no aumentan.

La reserva adicional de 1464 bytes en observation coincide con ese reset. [Observer.zig:337](../../../../src/backend/history/Observer.zig#L337) destruye y reinicializa su tracker y stream al recuperarse. Es un mecanismo compatible con los datos; sin traza de asignaciones no se atribuye esa reserva concreta a una instrucción. En el mismo proceso, 16600 bytes acumulados menos 14436 de crecimiento vivo equivalen a **2164 bytes liberados o reducidos**. No confundir crecimiento neto con bytes reservados acumulados ni presentar el heap menor del baseline variable como una mejora de memoria.

| Patrón y variante | RSS inicial | RSS final | Delta RSS | Heap vivo inicial → final |
|---|---:|---:|---:|---:|
| repeat, fase 1 | 29392896 | 44122112 | 14729216 | 15019358 → 15034494 |
| repeat, candidato | 29229056 | 44810240 | 15581184 | 15026052 → 15041188 |
| variable, fase 1 | 29147136 | 44974080 | 15826944 | 15019372 → 15033808 |
| variable, candidato | 29261824 | 44810240 | 15548416 | 15026066 → 15041202 |

Todos los valores de esta tabla son bytes. El scrollback contabilizado crece en los cuatro casos de 409600 a 9830400 bytes; `vt_screen_bytes` permanece en 117216. El RSS es del runtime completo y no equivale al heap instrumentado. Las muestras aproximadamente cada segundo, incluyendo la espera final, no prueban máximos instantáneos ni una relación causal entre el cambio y el delta de RSS.

Las colas publicadas terminan vacías. El máximo registrado de bytes en la cola media es 16384 en ambos baselines, 18432 en candidato repeat y 21504 en candidato variable; el máximo de eventos es dos en los cuatro. Son máximos acumulados del proceso, no contadores aditivos. No se publica en esta captura el número de bytes descartados por el batch de observación; tampoco se garantiza que las muestras periódicas observen toda ocupación transitoria.

Frase utilizable en el informe: «En los cuatro diagnósticos, el candidato reduce frames y trabajo de diff sin aumentar los bytes PTY procesados; el heap instrumentado crece 15136 bytes en ambas cargas del candidato. No aparecen nuevas asignaciones clasificadas como interactive-Telar, aunque sí reservas o crecimientos bajo VT y media. El baseline variable registra un descarte/reset de observación; los otros diagnósticos no incrementan los contadores de pérdidas consultados. Son observaciones de una corrida por condición, no una garantía general de ausencia de pérdidas o asignaciones.»
