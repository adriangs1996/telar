# Coste de la llamada virtual de `Memory`

`telar::Memory` pone un allocator detrás de `allocate` y `deallocate` virtuales
(P8.1). Esta página mide lo que cuesta esa llamada frente al concept
`Allocator`, con y sin ThinLTO y con `-fwhole-program-vtables`, y lo que cambia
ese flag en los hot paths del proxy y del render.

**Decisión: `-fwhole-program-vtables` no entra en release.** Con la visibilidad
actual no cambia nada. Para que actúe hace falta además `-fvisibility=hidden`,
y aun así no devirtualiza `Memory` cuando el binario tiene más de una
implementación, que es lo que tendrá tras P8.3. En los hot paths no da una
mejora consistente y la escena de texto pierde de forma consistente. Las
razones, con los números, están en [Decisión](#decisión).

## Cómo se mide

macOS ARM64, 10 núcleos, 32 GiB (`Personal`), LLVM 23.1.5, sobre `4d892812a`.
Todos los builds son Release y cada variante tiene su directorio. Las series
pasan por la puerta de carga de `tools/benchmark_host.py`; las que no la
superaron se repitieron enteras.

- **alloc+free:** `memory-call-probe` y `memory-call-probe-single`
  (`lib/base/tests`, target `base-probes`). Cada ronda mide el mismo bucle con
  `SystemAllocator` nombrado por su tipo (concept) y con `Memory &` (virtual),
  alternando cuál va primero. El `Memory &` viene de otra unidad de
  compilación y se elige en tiempo de ejecución, así que solo el enlace puede
  saber qué allocator responde. `-single` enlaza una implementación de
  `Memory`; el otro, tres (`SystemAllocator`, `BudgetAllocator` y
  `SynchronizedAllocator` detrás de `MemoryAdapter`), como un binario con
  varias raíces de composición. `tools/bench_memory_call.py` alterna las
  variantes de build: 7 pares de 21 rondas, 147 rondas por celda.
- **Hot paths:** las herramientas pareadas de
  `.claude/skills/perf-pass/measurement.md`, 7 pares alternos, más
  `src/runtime/tools/bench_proxy.py`, nuevo, que hace lo mismo con
  `proxy-probe` sobre un túnel CONNECT. Los oráculos (píxeles, vértices, bytes
  de eco y respuestas PTY) coinciden en todas las series.

Los casos del probe:

| Caso | Qué hace |
| --- | --- |
| `pair` | Un bloque de 8 a 1024 bytes que se libera enseguida, como un búfer temporal. |
| `batch` | 32 bloques vivos que se liberan juntos, como un mensaje o un frame. |
| `vector` | Un `Vector<std::uint32_t, A>` que crece hasta 1–48 elementos a través de `AllocatorRef`. |

Las variantes de build:

| Variante | Flags |
| --- | --- |
| sin LTO | `-DTELAR_THIN_LTO=OFF` |
| ThinLTO | la configuración de release actual |
| + WPV | ThinLTO y `-fwhole-program-vtables` al compilar y enlazar |
| + WPV + hidden | lo anterior y `-fvisibility=hidden` |

Para runtime y GUI, las variantes se llaman A (ThinLTO), B (+ WPV) y
C (+ WPV + hidden). Los flags se inyectan con `CMAKE_PROJECT_INCLUDE`, en
`CMAKE_CXX_COMPILE_OPTIONS_IPO` y `CMAKE_CXX_LINK_OPTIONS_IPO`, para que vayan
exactamente donde va `-flto=thin`. Si se pasan en `CMAKE_CXX_FLAGS_RELEASE`,
cambian la clave de las dependencias gestionadas y Qt se recompila (y falla:
`-fwhole-program-vtables` exige `-flto`). Tampoco pueden ir a todo el
directorio: `telar-clipboard` (Objective-C++) y el módulo `std` sintetizado
por CMake no compilan con LTO.

## alloc+free

Medianas en ns por operación. La diferencia es la mediana de las diferencias
por ronda. Concept y `Memory` se miden en el mismo proceso.

| Variante | Implementaciones | Caso | Concept | `Memory` | Diferencia | Rondas con `Memory` más lenta |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| sin LTO | 1 | `pair` | 27,29 | 28,06 | +0,64 | 142/147 |
| sin LTO | 1 | `batch` | 23,61 | 25,16 | +1,79 | 124/147 |
| sin LTO | 1 | `vector` | 120,84 | 138,59 | +17,83 | 147/147 |
| sin LTO | 3 | `pair` | 27,21 | 27,95 | +0,70 | 143/147 |
| sin LTO | 3 | `batch` | 23,35 | 24,72 | +1,66 | 114/147 |
| sin LTO | 3 | `vector` | 120,62 | 138,16 | +17,41 | 147/147 |
| ThinLTO | 1 | `pair` | 27,20 | 28,10 | +0,74 | 140/147 |
| ThinLTO | 1 | `batch` | 23,79 | 25,42 | +1,14 | 130/147 |
| ThinLTO | 1 | `vector` | 116,08 | 117,43 | +1,52 | 138/147 |
| ThinLTO | 3 | `pair` | 27,21 | 28,07 | +0,75 | 146/147 |
| ThinLTO | 3 | `batch` | 22,70 | 24,82 | +2,14 | 120/147 |
| ThinLTO | 3 | `vector` | 115,48 | 117,27 | +1,58 | 139/147 |
| + WPV | 1 | `pair` | 27,08 | 28,00 | +0,86 | 145/147 |
| + WPV | 1 | `batch` | 23,08 | 24,81 | +1,74 | 125/147 |
| + WPV | 1 | `vector` | 115,72 | 117,27 | +1,58 | 142/147 |
| + WPV | 3 | `pair` | 27,68 | 28,15 | +0,74 | 145/147 |
| + WPV | 3 | `batch` | 22,67 | 24,99 | +2,11 | 119/147 |
| + WPV | 3 | `vector` | 115,65 | 116,96 | +1,46 | 140/147 |
| + WPV + hidden | 1 | `pair` | 27,08 | 27,02 | −0,21 | 64/147 |
| + WPV + hidden | 1 | `batch` | 22,79 | 22,90 | +0,05 | 81/147 |
| + WPV + hidden | 1 | `vector` | 115,40 | 113,87 | −1,60 | 4/147 |
| + WPV + hidden | 3 | `pair` | 27,19 | 28,06 | +0,91 | 144/147 |
| + WPV + hidden | 3 | `batch` | 22,98 | 25,13 | +2,16 | 118/147 |
| + WPV + hidden | 3 | `vector` | 115,50 | 117,20 | +1,53 | 144/147 |

- **Con ThinLTO, la llamada virtual cuesta de +0,7 a +2,1 ns por alloc+free**
  sobre 23 a 27 ns de `malloc` y `free`: un 3 % en `pair`, un 9 % en `batch`.
  En `vector`, +1,5 ns por vector, un 1,3 %. El plan esperaba de +0,50 a
  +1,08 ns sin LTO; `pair` cae dentro y `batch` queda algo por encima.
- **Sin LTO, `vector` cuesta +17,8 ns (+15 %).** No es la llamada: con
  `Memory`, `__emplace_back_slow_path` deja de inlinearse en el bucle y se
  llama fuera de línea. ThinLTO lo vuelve a inlinear. Release ya enlaza con
  ThinLTO (P0.5), así que esto solo afecta a Debug.
- **`-fwhole-program-vtables` solo no hace nada.** Los dos probes salen
  idénticos byte a byte a los de ThinLTO.
- **Con `-fvisibility=hidden` y una sola implementación, la llamada
  desaparece.** El bucle de `Memory` llama a `malloc` y `free` directamente,
  igual que el concept, y las diferencias quedan en el ruido.
- **Con tres implementaciones no devirtualiza.** Queda la llamada indirecta y
  el coste es el de ThinLTO.

Desensamblado del bucle `pair` con `Memory &` y ThinLTO, por iteración: dos
cargas del vptr y del slot, `blr` a `MemoryAdapter<SystemAllocator>::allocate`
(que compara la alineación, porque llega como argumento, y salta a `malloc`)
y lo mismo para `deallocate` (`mov x0, x1; b free`). Con el concept, la
alineación es constante y el bucle llama a `malloc` y `free` con `bl`.

## Hot paths

### Qué cambia en los binarios

| Binario | A | B | C |
| --- | ---: | ---: | ---: |
| `telar-runtime` | 15 277 952 | idéntico a A | 15 255 472 (−0,15 %) |
| `telar-gui` | 20 591 336 | 20 591 016 | 20 465 704 (−0,61 %) |

| Binario | Llamadas indirectas (`blr`) en A | B | C |
| --- | ---: | ---: | ---: |
| `telar-runtime` | 6208 | 6208 | 6092 |
| `telar-gui` | 6655 | 6655 | 6639 |

B solo cambia la GUI, y no en llamadas indirectas: dos funciones
(`Application::presentChange` y una instancia de `Session::consume`) dejan de
tener símbolo propio porque se inlinean. La causa no está establecida. C quita
116 llamadas indirectas del runtime y 16 de la GUI; no se ha atribuido cada
una a su clase. Las únicas interfaces virtuales propias del runtime están en
el proxy (`FlowControl`, `HttpControl`, `PackagePort`). Las clases virtuales de
la GUI derivan casi todas de Qt, que se enlaza como framework dinámico con
visibilidad pública, así que no se devirtualizan.

Los builds en frío de la GUI tardan lo mismo en las tres variantes (77, 78 y
77 s); los del runtime con B y C, 54 y 55 s.

### Tiempos

A frente a C, salvo la última fila. Cambio es la mediana de los ratios por par;
victorias son los pares en que gana C (o B).

| Carga | A | C | Cambio | Victorias |
| --- | ---: | ---: | ---: | ---: |
| Proxy, `proxy-latency` (64 B por túnel) | 38 182 ns | 38 202 ns | +1,0 % | 3/7 |
| Proxy, `proxy-throughput` (64 KiB por túnel) | 76 092 ns | 76 794 ns | +0,5 % | 2/7 |
| Proxy, `proxy-connect` (túnel nuevo cada vez) | 229 179 ns | 224 665 ns | −2,2 % | 4/7 |
| PTY, `cursor-byte-writes` (p50) | 17 250 ns | 20 125 ns | +3,6 % | 2/7 |
| PTY, `mixed` (p50) | 19 166 ns | 19 291 ns | +5,1 % | 3/7 |
| PTY, `graphics-png-1x1` (p50) | 34 917 ns | 34 416 ns | −1,7 % | 6/7 |
| PTY, `graphics-png-512x512` (p50) | 763 541 ns | 762 042 ns | −0,3 % | 6/7 |
| PTY, resto (6 casos) | | | −7,8 % a +4,4 % | 2–4/7 |
| GUI, escena de terminal `full` | 5,898 ms | 5,802 ms | +0,8 % | 3/7 |
| GUI, escena de terminal `unicode` | 4,597 ms | 4,527 ms | −0,5 % | 6/7 |
| GUI, separadores de comandos | 7,510 ms | 7,678 ms | +2,9 % | 2/7 |
| GUI, escena de texto `create/128` | 4083 ns | 4183 ns | +3,3 % | **0/7** |
| GUI, escena de texto `create/32` | 1276 ns | 1300 ns | +2,8 % | **1/7** |
| GUI, escena de texto, resto (7 casos) | | | −0,1 % a +2,3 % | 2–4/7 |
| GUI, escena de terminal `full`, A frente a B | 5,757 ms | 5,715 ms | −0,2 % | 4/7 |

En el PTY, el script clasifica todos los casos como `inconclusive`, salvo los
dos de PNG, que quedan equivalentes dentro del 5 %. La escena de texto pierde
de forma consistente en `create/128` y `create/32`. No se ha comprobado si es
colocación, así que la causa no está establecida. Gana de forma consistente
solo `unicode`, por un 0,5 %.

## Decisión

`-fwhole-program-vtables` no entra en release:

1. **Solo no hace nada.** El runtime sale idéntico byte a byte y la GUI no
   pierde ninguna llamada indirecta. Clang solo devirtualiza clases con
   visibilidad LTO oculta, y sin `-fvisibility=hidden` casi ninguna clase de
   telar la tiene.
2. **Para que actúe hace falta `-fvisibility=hidden`, que es otra decisión.**
   Cambia la visibilidad de todos los símbolos y obliga a que ninguna clase
   con visibilidad LTO oculta tenga derivadas fuera de LTO, porque el enlace
   las daría por inexistentes. Hoy quedan fuera de LTO el Objective-C++
   (`telar-clipboard` y las unidades `.mm` de `src/gui/platform/macos`) y las
   dependencias gestionadas. El fallo sería una llamada virtual resuelta al destino
   equivocado, sin aviso.
3. **No devirtualiza `Memory` en la forma que tendrá en producción.** Tras
   P8.3, cada binario tendrá varias implementaciones de `Memory` (presupuesto,
   sincronizado, borrado, la que elija `TELAR_GUI_ALLOCATOR`), y con tres en
   el probe la llamada indirecta se queda. Con una sola sí desaparece.
4. **En los hot paths no compensa.** Con C, los cambios del proxy, del PTY y
   de la escena de terminal están en el ruido; la escena de texto pierde de
   forma consistente (`create/128` 0/7, `create/32` 1/7) y solo `unicode`
   gana de forma consistente, por un 0,5 %.

`Memory` no necesita el flag: con ThinLTO, la llamada virtual cuesta
de +0,7 a +2,1 ns sobre 23–27 ns de `malloc` y `free`. Donde eso pese, el
servicio puede tomar el allocator concreto, o llamar a través de
`MemoryAdapter<A> &`, que es `final` y se devirtualiza sin flags.

## Reproducir

```sh
tools/cpp configure release -B out/thin -- -DBUILD_TESTING=ON
tools/cpp build release -B out/thin -- --target base-probes
# Una variante más por directorio, por ejemplo -DTELAR_THIN_LTO=OFF, o
# -DCMAKE_PROJECT_INCLUDE con un fichero que añada los flags a
# CMAKE_CXX_COMPILE_OPTIONS_IPO y CMAKE_CXX_LINK_OPTIONS_IPO.
tools/bench_memory_call.py --variant thin=out/thin/lib/base --variant nolto=out/nolto/lib/base \
    --host-report /tmp/memory-call-host.json --output /tmp/memory-call.json

src/runtime/tools/bench_proxy.py \
    --baseline A/telar-runtime --baseline-probe A/proxy-probe \
    --candidate C/telar-runtime --candidate-probe C/proxy-probe \
    --host-report /tmp/proxy-host.json --output /tmp/proxy.json
```

`proxy-connect` abre dos sockets por iteración; con muchas más de las 300
iteraciones por ejecución que usa el script, macOS se queda sin puertos
efímeros (`Can't assign requested address`) mientras los anteriores siguen en
`TIME_WAIT`. Los comparadores de la GUI importan Pillow.

No se ha medido:

- x86-64 ni Linux con `ld.lld`: solo se ha ejecutado en macOS ARM64.
- `tools/gui_tui_latency.py`, que necesita Ghostty y la ventana en pantalla.
- Las queries de control (`bench_control_queries.py`), que comparan contra
  libghostty y no entre builds de telar.
