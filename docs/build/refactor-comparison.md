# Medición final del refactor frente a la línea base (P11.1)

Línea base: `docs/build/module-metrics.json` (grafo en `9289b7239`, P0.2). Final: `docs/build/module-metrics-final.json` (`0f73c2986`). Las dos salen de `tools/module-metrics.py`; las cifras de máquina son de `Adrians-MacBook-Pro` (8 núcleos, 16 GB) con `--build` en un directorio vacío.

## Grafo de módulos

| Cifra | Línea base | Final |
| --- | --- | --- |
| Módulos / componentes | 196 / 68 | 315 / 93 |
| Código en interfaces | 94,8 % (131 942 frente a 7 196 líneas) | 39,3 % (72 547 frente a 112 035) |
| Aristas | 1251 | 2227 |
| `export import` | 687 | 590 |
| Aristas hacia arriba (módulos / componentes) | 56 / 41 | 0 / 0 |
| Ciclos | 5 | 0 |
| Camino crítico | 21 módulos | 21 módulos |

Dependientes transitivos de los hubs. `telar.client.protocol` ya no existe (sus mensajes están en `telar.wire.*`) y `telar.base.memory` se partió; se dan los equivalentes:

| Línea base | Final |
| --- | --- |
| `telar.client.protocol` 148 de 196 (76 %) | `telar.wire.vocabulary` 188 de 315 (60 %) |
| `telar.base.memory` 169 de 196 (86 %) | `telar.base.memory.allocators` 246 de 315 (78 %) |

## Build

| Cifra | Línea base | Final |
| --- | --- | --- |
| Unidades de compilación (runtime + GUI) | 360 + 792 = 1152 | 850 + 1195 = 2045 |
| Líneas en fragmentos globales (sin blancos ni comentarios) | 1 793 644 en 229 unidades, mediana 3480 | 737 199 en 593 unidades, mediana 0 |
| Build en frío sin configure | 140,8 s | 104,6 s |
| Pico de memoria del build en frío | 3481 MiB | 2634 MiB |

Unidades que lista `ninja -n` al tocar la interfaz de cada hub (`--hubs`). Línea base, de 1152: `telar.base.memory` 479 (41,6 %), `telar.base.diagnostics` 478 (41,5 %), `telar.base.text` 477 (41,4 %), `telar.client.protocol` 435 (37,8 %), `telar.platform.primitives` 449 (39,0 %), `telar.vocabulary` 457 (39,7 %), `telar.platform` 448 (38,9 %), `telar.client` 432 (37,5 %). Final, de 2045: `telar.tbc` 913 (44,6 %), `telar.base.memory.allocators` 902 (44,1 %), `telar.base.memory.containers` 895 (43,8 %), `telar.base.diagnostics` 894 (43,7 %), `telar.base.text.utf8` 895 (43,8 %), `telar.base.text.json` 893 (43,7 %), `telar.sys.socket` 913 (44,6 %), `telar.base.text` 892 (43,6 %).

`ninja -n` no aplica `restat`, así que es una cota superior. Con builds reales en el árbol de la medición final (tocar un solo fichero, compilar y contar las unidades compiladas):

| Fichero tocado | Runtime | GUI |
| --- | --- | --- |
| `lib/base/text/text.cpp` (implementación) | 1 | 1 |
| `lib/wire/vocabulary/vocabulary.cpp` (implementación) | 1 | 1 |
| `src/runtime/runtime/runtime/runtime.cpp` (implementación) | 1 | 0 |
| `lib/base/text/text.cppm` (interfaz, solo la fecha) | 351 | 405 |
| `lib/base/memory/allocators/allocators.cppm` (interfaz, solo la fecha) | 433 | 461 |

Tocar la interfaz de un hub recompila casi lo mismo que predice `ninja -n`, y en proporción algo más que antes: del 37,5–41,6 % del árbol en la línea base al 43,6–44,6 % ahora, con casi el doble de unidades porque cada módulo tiene su interfaz y su implementación separadas. Tocar una implementación recompila una sola unidad. En la línea base el 94,8 % del código estaba en interfaces, así que casi cualquier cambio pasaba por una; ahora es el 39,3 %. Las líneas en fragmentos globales bajan a un 41 % con 2,6 veces más unidades, y la mediana por unidad pasa de 3480 a 0. El camino crítico sigue en 21 módulos. El build en frío baja de 140,8 s a 104,6 s y su pico de memoria de 3481 a 2634 MiB.
