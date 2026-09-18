# Contingencia de fase 3: GUI de 64 MiB

La extensión se fijó después de observar variabilidad en las ráfagas de 8 MiB y antes de ejecutar cualquier corrida nueva de GUI de 64 MiB. El coordinador ya había visto resultados parciales de 8 MiB al solicitarla y conoció el resultado variable inconcluso antes de cerrar esta preparación. Por tanto, no fue una predeclaración anterior a los resultados originales. El borrador previo se conserva como `tgb-phase3-long-protocol.v1.md`.

El tamaño nuevo queda cerrado en ocho pares y 64 MiB por payload antes de comenzar esta extensión independiente. La preparación sólo copia y modifica herramientas; no ejecuta aplicaciones, compilaciones, pruebas ni benchmarks.

## Condición de activación

Ejecutar únicamente si la comparación final de GUI de 8 MiB deja inconcluso el criterio de conservación del caudal. No usar esta contingencia para sustituir una regresión concluyente. La decisión de activarla corresponde al coordinador después de analizar y conservar íntegra la confirmación original.

Una activación abre una confirmación independiente, con tamaño cerrado de ocho pares por patrón, payloads de 64 MiB ASCII y ANSI, margen de pérdida del 5% y sin ampliaciones posteriores según el resultado. Su finalidad es reducir el peso del ruido en ráfagas de aproximadamente 100 ms. No garantiza que el resultado deje de ser inconcluso.

## Diseño cerrado

A es `/tmp/tgb-phase2-stable/bin/telar`; B es `/tmp/tgb-phase3-candidate/bin/telar`. Mantener sus hashes. Cada patrón tiene ocho rondas de `single`, AB en rondas pares y BA en impares. Ejecutar primero variable y después repeat, serialmente. Son 16 pares, 32 ejecuciones de GUI y 64 payloads de 67.108.864 bytes. El orden de patrones queda fijado, por lo que se comparan A y B dentro de cada patrón y no tasas entre bloques de patrones.

Cada ejecución conserva 20 entradas de warmup y una entrada medida por compatibilidad con la sonda. Esa única latencia no sustenta conclusiones de latencia. La medición de caudal termina en la respuesta DSR. Conservar viewport 1000×700, geometría PTY, foco, tamaños, hashes, errores y limpieza. No hay productores de fondo en `single`.

No mezclar estas observaciones con las ráfagas originales de 8 MiB, con exploraciones ni con TUI sostenido. Las conclusiones originales permanecen visibles, incluso si esta confirmación produce un resultado más favorable.

## Herramientas y alcance del cambio

Las herramientas se copian del archivo congelado `/tmp/tgb-p3-final-variable/harness` a `/tmp/tgb-p3-long-tools`. Sólo cambia `PAYLOAD_BYTES` de 8 a 64 MiB en `terminal_bench_fixture.py` y la validación de bytes de `gui_tui_latency.py`. La ayuda del CLI privado sigue describiendo 8 MiB porque ese CLI no se usa: el runner importa `measure`. El fixture variable prepara un corpus de 64 MiB fuera del cronómetro. `gui_tui_latency.m` permanece idéntico al setup `/tmp/tgb-p3-setup`; se reutilizan su biblioteca, configuración y bundle privados.

El runner `/tmp/tgb-phase3-native.py` permanece intacto. El analizador nuevo `/tmp/tgb-phase3-long-analyze.py` exige 67.108.864 bytes, calcula MiB/s con 64.000 dividido por milisegundos y expone explícitamente el cumplimiento de ocho pares. Los cuatro estratos siguen siendo repeat/ASCII, repeat/ANSI, variable/ASCII y variable/ANSI. El diff exacto está en `/tmp/tgb-p3-long-contingency.patch` y los hashes en `/tmp/tgb-p3-long-contingency.json`.

## Límites de tiempo conservados

El payload de cada caso contiene exactamente 67.108.864 bytes. Su generación y SHA terminan antes de iniciar el cronómetro. Se conserva la comprobación del tamaño del PTY y de su generación entre el inicio y el final de cada caso.

No cambia ningún timeout. El fixture espera como máximo 25 s a `viewport.ready`; cada espera de respuesta DSR tiene un límite de 15 s. La sonda permite 35 s para todo el setup, incluida la preparación y los dos casos de caudal; el fixture tiene una alarma total de 75 s, la sonda termina a los 90 s y Python limita el proceso a 105 s. Estos presupuestos se reinician por ejecución, no se comparten entre los ocho pares.

El watchdog de input de 2 s se arma al inyectar cada tecla. Las teclas medidas empiezan cuando el fixture publica `ready`, después de ambos payloads; por tanto, ese watchdog no limita cada ráfaga de caudal. Un bloqueo de escritura puede alcanzar los límites globales aunque la espera DSR todavía no haya empezado. Si se agota un presupuesto, se conserva el fallo y no se amplía el límite durante la serie.

## Comandos reservados

No ejecutados durante la preparación. Usar carpetas nuevas. Quitar `TGB_DRAW_DIAGNOSTICS` del entorno mantiene la instrumentación de diagnóstico adicional apagada.

```sh
env -u TGB_DRAW_DIAGNOSTICS python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools /tmp/tgb-p3-long-tools \
  --output /tmp/tgb-p3-long-variable --rounds 8 --samples 1 \
  --cases single --text-pattern variable --record-rate-misses

env -u TGB_DRAW_DIAGNOSTICS python3 /tmp/tgb-phase3-native.py \
  --baseline /tmp/tgb-phase2-stable/bin/telar \
  --candidate /tmp/tgb-phase3-candidate/bin/telar \
  --setup-dir /tmp/tgb-p3-setup --tools /tmp/tgb-p3-long-tools \
  --output /tmp/tgb-p3-long-repeat --rounds 8 --samples 1 \
  --cases single --text-pattern repeat --record-rate-misses

python3 /tmp/tgb-phase3-long-analyze.py \
  /tmp/tgb-p3-long-variable /tmp/tgb-p3-long-repeat \
  --output /tmp/tgb-p3-long-analysis.json
```

## Regla de decisión y fallos

Por estrato, calcular los ocho cocientes B/A y su media geométrica. Remuestrear pares completos 10.000 veces, semilla 20260918. El límite inferior unilateral del 95%, percentil 5 de las medias geométricas remuestreadas, debe ser al menos 0,95 en cada uno de los cuatro estratos. Si el límite superior unilateral, percentil 95, queda por debajo de 0,95, registrar evidencia de pérdida superior al margen; en los demás casos registrar resultado inconcluso. No combinar estratos para compensar una regresión.

Ocho pares siguen ofreciendo cobertura limitada. La regla es operativa para estas cargas, no una prueba de equivalencia poblacional. Si queda inconclusa, informar la incertidumbre y detener esta confirmación; no aumentar payloads o rondas hasta obtener éxito.

Conservar todos los valores válidos, incluidos extremos. Sólo se permiten los reintentos existentes de arranque sin ventana ni muestras. Un fallo de foco, geometría, payload, sonda o limpieza detiene la serie y se conserva como fallo; no sustituirlo por una corrida favorable. Guardar por separado esta contingencia, sus manifests, comandos, fuentes y resultados originales de 8 MiB.
