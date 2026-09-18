# Perfil después de agrupar publicaciones

El temporizador estable elimina casi toda la presencia de señales de cancelación observada en el candidato anterior: `_sigtramp` pasa de **704 a 1 muestras** entre workers; las situadas bajo los workers hijos del temporizador pasan de **655 a 1**. Es coherente con conservar el plazo armado cuando llegan `null` o plazos posteriores. Estos conteos no son llamadas ni porcentajes de ahorro de CPU.

| Main: muestras inclusivas | Fase 2 inicial, n=5.711 | Temporizador estable, n=5.920 |
| --- | ---: | ---: |
| `CellSync.prepare` | 17 (0,30%) | 8 (0,14%) |
| `blit`, incluido en preparación | 8 (0,14%) | 4 (0,07%) |
| `tcgetpgrp` | 477 (8,35%) | 454 (7,67%) |
| `groupConcurrent` | 222 (3,89%) | 208 (3,51%) |
| `scheduleCellPublication` | 17 (0,30%) | 2 (0,03%) |
| Espera futex | 4.581 (80,21%) | 4.856 (82,03%) |

La preparación de celdas sigue muy lejos de las **1.386/5.853 muestras (23,68%)** de fase 1. Sus ramas de render, blit y comparación de estilos están anidadas: no se suman.

El candidato restante más claro en el main es `tcgetpgrp`: `GenericPipeline.zig:64` llama a `Session.shellForeground`, que acaba en `native.zig:87`, **una vez por lote PTY no vacío**. El resultado controla progreso y atribución del historial. El worker de observación vuelve a consultar el grupo por lote (`GenericProjectionDispatcher.zig:114`): allí aparecen otras 263 muestras, con denominador distinto.

En los workers, `observePane` reúne **3.918 muestras**, incluidas **1.906 de `Sample.signal`** y 425 de captura. `Sample.signal` (`Sample.zig:52`) ejecuta heurísticas de frases de manifiestos mediante `Table.detect`; no es una señal del sistema operativo. `Observer.zig:223` lo llama al terminar cada lote con salida, si el parser está en estado ground y fuera de synchronized output. Merece medir cuánto trabajo se repite sobre pantallas iguales, conservando timestamps y transiciones aunque se reutilizase una detección.

Media reúne **1.727 muestras**, incluidas 1.511 de `ingestMediaOutput`, frente a 386 de ingestión canónica. `Processor.zig:242` observa framing Kitty y vuelve a parsear los bytes en el VT de media; cualquier optimización debe preservar cursor, scroll y protocolo. Estas ramas de workers tampoco prueban por sí solas qué limita el caudal.

El **82,03% de espera del main no demuestra un cuello en IPC**. Las 5.563 muestras de espera del temporizador y 5.661 de lectura del socket tampoco representan CPU consumida. El perfil incluye un tramo inicial de hashing/idle y el comienzo de ASCII: se pidieron 8 s, mientras ASCII de 1 GiB duró 14,144 s. No incluye ANSI. Hay un perfil por versión; las mejoras de caudal y latencia deben salir de las rondas sin profiler.

Evidencia: [perfil estructurado](raw/final/followup/raw/profile-candidate-repeat/profile-analysis.json), con líneas del call graph, hashes, denominadores y referencias al perfil anterior. El parser verifica los conteos por hilo y evita contar dos veces nodos con un ancestro ya incluido.
