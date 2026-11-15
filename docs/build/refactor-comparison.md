# Medición final del refactor frente a la línea base (P11.1)

Línea base: `docs/build/module-metrics.json` (grafo en `9289b7239`, P0.2). Final: `docs/build/module-metrics-final.json` (grafo en `9c7175260`; las dos máquinas midieron el mismo código, `Adrians-Laptop` sobre `a02a326bc`, que solo difiere en `TODO.md`). Las dos salen de `tools/module-metrics.py` con `--build` en un directorio vacío.

## Grafo de módulos

| Cifra | Línea base | Final |
| --- | --- | --- |
| Módulos / componentes | 196 / 68 | 315 / 93 |
| Código en interfaces | 94,8 % (131 942 frente a 7 196 líneas) | 39,3 % (72 581 frente a 112 035) |
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

## Build, por máquina

### `Adrians-MacBook-Pro` (8 núcleos, 16 GB)

| Cifra | Línea base | Final |
| --- | --- | --- |
| Unidades de compilación (runtime + GUI) | 360 + 792 = 1152 | 850 + 1195 = 2045 |
| Líneas en fragmentos globales (sin blancos ni comentarios) | 1 793 644 en 229 unidades, mediana 3480 | 737 199 en 593 unidades, mediana 0 |
| Build en frío sin configure | 140,8 s | 107,8 s |
| Pico de memoria del build en frío | 3481 MiB | 2602 MiB |

Unidades que lista `ninja -n` al tocar la interfaz de cada hub. Línea base, de 1152: `telar.base.memory` 479 (41,6 %), `telar.base.diagnostics` 478 (41,5 %), `telar.base.text` 477 (41,4 %), `telar.client.protocol` 435 (37,8 %), `telar.platform.primitives` 449 (39,0 %), `telar.vocabulary` 457 (39,7 %), `telar.platform` 448 (38,9 %), `telar.client` 432 (37,5 %). Final, de 2045: `telar.tbc` 913 (44,6 %), `telar.base.memory.allocators` 902 (44,1 %), `telar.base.memory.containers` 895 (43,8 %), `telar.base.diagnostics` 894 (43,7 %), `telar.base.text.utf8` 895 (43,8 %), `telar.base.text.json` 893 (43,7 %), `telar.sys.socket` 913 (44,6 %), `telar.base.text` 892 (43,6 %).

### `Adrians-Laptop` (`Personal`, 10 núcleos, 32 GB)

| Cifra | Línea base | Final |
| --- | --- | --- |
| Unidades de compilación (runtime + GUI) | 360 + 794 = 1154 | 850 + 1195 = 2045 |
| Líneas en fragmentos globales (sin blancos ni comentarios) | 1 866 955 en 231 unidades, mediana 3494 | 738 086 en 593 unidades, mediana 0 |
| Build en frío sin configure | 128,0 s | 72,1 s |
| Pico de memoria del build en frío | 7547 MiB | 4478 MiB |

Unidades que lista `ninja -n` al tocar la interfaz de cada hub. Línea base, de 1154: `telar.base.memory` 480 (41,6 %), `telar.base.diagnostics` 479 (41,5 %), `telar.base.text` 478 (41,4 %), `telar.client.protocol` 436 (37,8 %), `telar.platform.primitives` 450 (39,0 %), `telar.vocabulary` 458 (39,7 %), `telar.platform` 449 (38,9 %), `telar.client` 433 (37,5 %). Final, de 2045: `telar.tbc` 913 (44,6 %), `telar.base.memory.allocators` 902 (44,1 %), `telar.base.memory.containers` 895 (43,8 %), `telar.base.diagnostics` 894 (43,7 %), `telar.base.text.utf8` 895 (43,8 %), `telar.base.text.json` 893 (43,7 %), `telar.sys.socket` 913 (44,6 %), `telar.base.text` 892 (43,6 %).

## Recompilación real

`ninja -n` no aplica `restat`, así que es una cota superior. Con builds reales en el árbol de la medición final de `Adrians-MacBook-Pro` (tocar un solo fichero, compilar y contar las unidades compiladas):

| Fichero tocado | Runtime | GUI |
| --- | --- | --- |
| `lib/base/text/text.cpp` (implementación) | 1 | 1 |
| `lib/wire/vocabulary/vocabulary.cpp` (implementación) | 1 | 1 |
| `src/runtime/runtime/runtime/runtime.cpp` (implementación) | 1 | 0 |
| `lib/base/text/text.cppm` (interfaz, solo la fecha) | 351 | 405 |
| `lib/base/memory/allocators/allocators.cppm` (interfaz, solo la fecha) | 433 | 461 |

## Lectura

Tocar la interfaz de un hub recompila casi lo mismo que predice `ninja -n`, y en proporción algo más que antes (del 37,5–41,6 % del árbol al 43,6–44,6 %), con casi el doble de unidades porque cada módulo tiene su interfaz y su implementación separadas. Tocar una implementación recompila una sola unidad; en la línea base el 94,8 % del código estaba en interfaces, así que casi cualquier cambio pasaba por una, y ahora es el 39,3 %. No quedan aristas hacia arriba ni ciclos, y hay 97 `export import` menos. Las líneas en fragmentos globales bajan a un 41 % con 2,6 veces más unidades y la mediana por unidad pasa de unas 3500 a 0. El build en frío y su pico de memoria bajan en las dos máquinas. El camino crítico sigue en 21 módulos.

## Fase 12: dependencias explícitas

Después de P11.1 (`9c7175260`), la fase 12 prohíbe `export import` salvo el de particiones propias y añade la regla de imports sin usar. Medido en `docs/build/module-metrics-p12.json` (`c3fff39b8` en `Adrians-MacBook-Pro`, `0593ddad1` en `Adrians-Laptop`; el grafo es el mismo en los dos).

| Cifra | P11.1 | Fase 12 |
| --- | --- | --- |
| Aristas | 2227 | 2279 |
| `export import` | 590 | 24 (todos de particiones propias) |
| Camino crítico | 21 módulos | 20 módulos |
| Código en interfaces | 39,3 % | 39,2 % |
| `telar.base.memory.allocators`, dependientes | 246 | 245 |
| `telar.tbc`, dependientes | 250 | 247 |

`Adrians-MacBook-Pro`: build en frío 107,8 → 102,9 s (pico 2602 → 2444 MiB); líneas en fragmentos globales 737 199 → 737 199; `ninja -n` al tocar `telar.base.memory.allocators` 902 → 901 unidades.

`Adrians-Laptop`: build en frío 72,1 → 71,7 s (pico 4478 → 4697 MiB); líneas en fragmentos globales 738 086 → 738 086; `ninja -n` al tocar `telar.base.memory.allocators` 902 → 901 unidades.

Las aristas suben porque cada fichero importa ahora lo que nombra en vez de recibirlo por un re-export: las dependencias que antes eran implícitas quedan escritas. El código generado no cambia: el desensamblado de `telar-runtime`, `telar` y `telar-gui` en Release de `0593ddad1` es idéntico, instrucción a instrucción, al de `9c7175260` (el único cambio posterior, `c3fff39b8`, saca de un bloque de macOS un import que también hace falta en Linux), y solo cambian datos (números de línea de `std::source_location`, rutas, marcas de tiempo de recursos y la firma).
