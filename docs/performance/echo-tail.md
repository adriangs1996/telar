# Investigación de la cola de latencia del eco

6 de septiembre de 2026. Rama `perf/echo-tail`, desde `a5876ed`.

**La reducción de p99 sigue sin demostrarse.** Esta entrega añade diagnóstico y
conserva los experimentos, no una nueva optimización de producción. El ejecutable
sin tracer tiene todas sus secciones `__TEXT` idénticas al de partida.

La pregunta es dónde pasan el tiempo las pulsaciones lentas. Que el filtro cueste
menos que despachar el trabajo justifica el ahorro local; no basta para aprobar
el efecto sobre toda la distribución. El objetivo sigue siendo bajar p99 y
`p99 − p50`, sin subir p50 ni introducir espera activa.

## Qué se puede afirmar

### Hay picos sin Telar

Repetí el fixture de aplicación raw con pausa de 50 ms, 200 muestras por ejecución
y cinco repeticiones, usando solo los controles nativos. El oráculo, geometría
y protocolo de estímulo/borrado son los del [informe de eco](echo.md).

| Control | p50 por ejecución, µs | p99 por ejecución, µs |
|---|---|---|
| PTY directo | 27,3 / 51,1 / 28,2 / 41,3 / 38,9 | 355,2 / **13.069,5** / 115,6 / 150,1 / 190,4 |
| Relay de dos procesos | 88,4 / 103,2 / 56,0 / 74,0 / 163,1 | **12.514,9** / 4.497,7 / 222,7 / 333,7 / 451,7 |

El máximo del PTY directo fue 24.563 µs. No ejecuta Telar y no tiene su filtro,
VT del runtime ni sus actores. Esos picos pertenecen al entorno o al propio
fixture, que incluye aplicación raw, kernel, driver Python y oráculo.

Una inspección del host durante la investigación mostró actividad de Chrome,
WindowServer, pi, Ghostty y otros procesos. Eso no identifica qué proceso causó
cada pico. Tampoco el swap usado demuestra por sí solo presión de memoria activa.
No se cerraron aplicaciones ajenas ni se cambió la configuración de energía.

Esto **no explica retroactivamente el +17,5% de p99 del informe anterior**, ni
permite retirarlo de los resultados. Impide usar estas nuevas comparaciones como
prueba de que una modificación corrige o empeora esa regresión.

### El tiempo transcurrido no es todo tiempo de ejecución

El tracer opcional ahora añade reloj de CPU del hilo e identidad de hilo/proceso.
El runner registra comienzo del estímulo, retorno de la escritura y llegada de la
respuesta. El analizador solo resta relojes de CPU del mismo hilo y proceso;
conserva residuos negativos debidos al muestreo y no los convierte en cero.

Ejemplos concretos de las trazas de aplicación raw:

| Captura | Tramo | Tiempo transcurrido | CPU del hilo |
|---|---|---:|---:|
| Smoke, muestra 107 | runtime dispatch → input forward | 876,750 µs | 16,4 µs |
| Serie 4, muestra 190 | client send start → send done | 679,417 µs | 29,958 µs |

El primer intervalo contenía un único `runtime_dispatch` anterior a
`input_forward`. El segundo está delimitado dentro de la función de envío.
No son dos relojes de procesos distintos restados entre sí.

La mayor parte de esos intervalos no fue CPU de ese hilo. Esto no distingue,
sin una traza del scheduler, entre desplanificación, bloqueo o fallo de página.
No lo etiqueto automáticamente como coste de una cola de Telar.

En otro eco, serie 2, muestra 120, el envío del runtime terminó a 525,042 µs desde
el estímulo y el lector del cliente marcó recepción a 1.070,917 µs. El retraso
estaba después de terminar el envío, no en ejecutar el filtro de admisión.

También hay trabajo síncrono medible. La consulta de foreground de la serie 1,
muestra 126, ocupó 174,042 µs transcurridos y 174,125 µs de CPU. La pequeña
inversión entre ambos relojes recuerda que la instrumentación tiene coste y
resolución. No todo el tiempo alto se puede atribuir a desplanificación.

La serie posterior contiene cinco trazas de 200 ecos completos. Sus p99 fueron
873,0 / 909,4 / 846,0 / 844,3 / 904,5 µs. Son cifras **instrumentadas**, no resultados
de producción ni comparables directamente con los percentiles anteriores.

## Experimentos que no se incorporan

- **QoS interactivo del hilo principal.** Dos parejas AB/BA, 100 muestras.
  Los cambios de p99 tuvieron signos opuestos. No hay mejora demostrada.
- **QoS de los trabajos de I/O y VT, además del principal.** Dos parejas, 200
  muestras. También dio resultados contradictorios. El prototipo restaura la
  clase al salir, pero no constituye una política de producción completa.
- **Sin inspección de foreground.** Cinco parejas, 200 muestras. Solo como
  ablación del fixture, donde la aplicación permanece como líder de sesión.
  El p95 bajó en las cinco parejas, pero p50 cambió de signo y la última pareja
  sufrió p99 de 45.023 µs. Devolver un foreground inventado no es una solución:
  rompería la observación de trabajos reales. Se restauró la consulta original.

Los parches experimentales y los resultados completos se conservan en
`echo-tail/`. No quedó QoS experimental, caché de foreground ni consulta eliminada
en el código entregado. No se convirtió ningún descriptor compartido a modo no
bloqueante ni se adelantó un ACK.

## Qué falta para corregirlo

1. Repetir AB/BA en Ubuntu 24.04 x86_64 nativo, o usar primero una ventana tranquila
   de este Mac para diagnóstico local. No cambiar la carga entre variantes.
   Registrar también el control directo durante esa ventana.
2. Ampliar las ejecuciones sin tracer a 2.000 muestras. Con 200, p99 queda cerca
   de las dos muestras más lentas y es sensible a pocos picos. Más muestras no
   sustituyen un host comparable.
3. Separar la cola dentro de los envíos de la espera de recepción y del despacho.
   Las nuevas marcas permiten localizar candidatos; una traza del scheduler debe
   resolver qué está bloqueado o desplanificado. Las marcas genéricas de mensajes
   no son IDs causales de protocolo: ACK y metadatos pueden intercalarse.
4. Comparar una modificación cada vez. Reducir handoffs es una opción a investigar,
   no una mejora medida todavía. Una política de prioridad tampoco puede promover
   trabajo pesado de media/observación junto con el interactivo.
5. Aprobar p50, p95, p99, su dispersión y la distancia absoluta p99 − p50. Mantener
   los tests de host bloqueado, cancelación y propiedad de buffers. No subir p50
   para hacer que el cociente p99/p50 parezca mejor.

No se puede prometer una cota máxima de latencia end to end en este entorno
sin planificación de tiempo real. Sí podemos reducir trabajo y esperas de Telar;
aún no hay evidencia suficiente para presentar un cambio como solución a esta cola.

## Herramientas y validación

`-Decho-trace-cpu=true` añade CPU e identidad de hilo solamente cuando está activo
`-Decho-trace=true`. Mantiene el límite de 16.384 registros por proceso y el dump
posterior al join. Las lecturas adicionales de reloj perturban la ejecución.

```sh
zig build -Doptimize=ReleaseFast -Ddiagnostics=false \
  -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/tt/cpu
python3 tools/echo_path.py --probe /tmp/te/probe/bin/echo-probe \
  --candidate /tmp/tt/cpu/bin/telar --output /tmp/tt/run \
  --application --trace --samples 200 --repetitions 5 --controls
python3 tools/echo_tail.py /tmp/tt/run
```

El analizador comprueba cantidad de cadenas, timestamps, epoch compatible y
monotonía. Distingue duraciones de envío de los intervalos entre procesos.
No extrapola la correlación del fixture a tráfico general o múltiples panes.

Debug y ReleaseFast: 82/82 pasos y 3.487/3.487 tests en cada modo. Nueve tests
Python. Se verificaron los dumps CPU, las cadenas completas y la equivalencia
de las secciones `__TEXT` del build sin tracer. No se ha ejecutado el gate oficial.
