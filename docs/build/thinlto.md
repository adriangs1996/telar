# ThinLTO en los builds optimizados

Release y RelWithDebInfo enlazan con ThinLTO. Lo activa `cmake/cpp_modules.cmake`,
que incluyen todos los proyectos, así que cubre release (`packaging/release/*`,
`just install-gui`) y dev-release (`just app-release`) sin tocar sus comandos.

- La IPO de CMake compila con `-flto=thin` y archiva con el `llvm-ar` y el
  `llvm-ranlib` del toolchain, que indexan el bitcode de las bibliotecas estáticas.
- En macOS enlaza ld64. Clang le pasa el `libLTO.dylib` de su propio toolchain,
  que lee el bitcode de LLVM 23; el del sistema no lo leería.
- En Linux enlaza `ld.lld`, que el bootstrap ya exige. GNU ld necesitaría un
  plugin de gold que el toolchain no trae.
- Cada árbol de build guarda una caché en `<build>/thinlto-cache`: al reenlazar,
  los módulos cuyo resumen no cambió reutilizan su código objeto.
- Las dependencias de `telar_managed_build` siguen siendo objetos nativos y su
  clave no cambia.
- `-DTELAR_THIN_LTO=OFF` lo desactiva. Con la opción apagada, `telar-runtime` y
  `telar` salen idénticos byte a byte a los de antes del cambio.

## Medidas

macOS ARM64, 10 núcleos, 32 GiB, LLVM 23.1.5, desde `a1e1beb3c`. A es el build
sin ThinLTO y B el build con ThinLTO, cada uno en su directorio. Los builds
cronometrados usan `-DBUILD_TESTING=OFF`, como release y dev-release. Las
dependencias gestionadas, Qt y libghostty-vt ya estaban en caché, así que el
build en frío mide solo el código de telar.

### Tamaño

| Binario | A | B | Cambio |
| --- | ---: | ---: | ---: |
| `telar-runtime` | 18 364 608 | 15 303 536 | −16,7 % |
| `telar` | 9 196 856 | 6 691 032 | −27,2 % |
| `telar-gui` | 24 932 456 | 20 590 568 | −17,4 % |
| `telar-gui-command` | 33 776 | 33 776 | = |

### Tiempo de build

En frío (`tools/cpp build`; tiempo real y CPU de usuario, dos muestras por variante):

| Proyecto | A | B |
| --- | --- | --- |
| runtime (`telar-runtime telar`) | 52,3 s / 116 s; 53,7 s / 117 s | 54,2 s / 127 s; 51,3 s / 125 s |
| GUI (`telar-gui telar-gui-command`) | 62,6 s / 268 s; 76,7 s / 284 s | 86,0 s / 309 s; 57,9 s / 283 s |

La diferencia en tiempo real queda dentro del ruido entre muestras. El runtime
gasta un 8 % más de CPU.

Incremental: se cambia el cuerpo de una función y se reconstruye. Son el
compilado, el archivo y el enlace.

| Cambio | A | B |
| --- | --- | --- |
| `checkSqlite` en `history/database.cpp` (runtime) | 1,1 s; 2,7 s; 1,2 s | 17,3 s; 18,5 s; 18,0 s |
| `WallClock::sample` en `platform/wall_clock.cpp` (GUI) | 1,2 s | 2,7 s |
| Volver al contenido anterior (runtime / GUI) | 1,2 s / 1,2 s | 1,2 s / 1,5 s |

Casi todo el tiempo del runtime en B se va en enlazar `telar-runtime`, en el
backend de ThinLTO. Al volver a un contenido que ya está en la caché, el enlace
vuelve a tardar lo mismo que sin LTO.

### Benchmarks de hot path

Herramientas pareadas de `.agents/skills/perf-pass/measurement.md`, 7 pares
alternos A/B, con el host por debajo de los límites de carga de
`tools/benchmark_host.py`. Las victorias son los pares en que gana B. El oráculo
de píxeles de los comparadores de GUI da una diferencia máxima de 0 en todas
las cargas.

| Carga | A | B | Cambio | Victorias |
| --- | ---: | ---: | ---: | ---: |
| GUI, escena de terminal `full` | 6,243 ms | 5,903 ms | −5,4 % | 5/7 |
| GUI, escena de terminal `unicode` | 4,901 ms | 4,927 ms | +0,5 % | 3/7 |
| GUI, separadores de comandos | 6,981 ms | 7,066 ms | +1,2 % | **1/7** |
| GUI, escena de texto `create/512` | 16 011 ns | 15 637 ns | −2,3 % | 6/7 |
| GUI, escena de texto, resto (8 casos) | | | −4,0 % a +1,1 % | 3–5/7 |
| PTY, `cursor-byte-writes` (p50) | 20 042 ns | 16 666 ns | −16,8 % | 6/7 |
| PTY, `mixed` (p50) | 21 041 ns | 19 167 ns | −8,9 % | 6/7 |
| PTY, `cursor` (p50) | 18 875 ns | 20 541 ns | +8,8 % | 3/7 |
| PTY, resto (7 casos, mediana del ratio por par) | | | −4,5 % a +2,0 % | 3–4/7 |
| Queries de control (35 casos, mediana del ratio) | | | 0,995 a 1,006 | 0–7/7 |

En las queries de control, `mode-report` pierde los 7 pares por un 0,2 % (en
una primera serie ganó 2/7). `ordinary-styled` gana los 7 por un 0,3 %. Casi
todo el trabajo de este benchmark ocurre en libghostty-vt, que está compilada
con Zig y queda fuera de ThinLTO.

No se ha medido:

- `tools/gui_tui_latency.py`, porque necesita Ghostty y la ventana en pantalla.
- El enlace con `ld.lld` en Linux, porque solo se ha ejecutado en macOS.

## Para P9

- **Separadores de comandos:** +1,2 % y 1/7 victorias. Por la regla de
  aceptación es una pérdida consistente. No se ha comprobado si es colocación
  (desensamblado normalizado idéntico), así que la causa no está establecida.
- **`mode-report` en las queries de control:** +0,2 % con 0/7 en una serie y
  2/7 en otra. Está en el límite del ruido y la causa no está establecida.
- **Reenlazar el runtime:** ahora cuesta unos 17 s más cada vez que cambia un
  cuerpo. P9 saca cuerpos de las interfaces, así que hay que repetir esta
  medida a lo largo de P9 y en P11.1.

## Marcos de pila

ThinLTO decide qué se inserta al enlazar, así que un marco puede crecer sin que
cambie su código: basta con que el enlazador inserte en él a quien lo llama o a
quien llama. Así nació el SIGBUS de `gui-quick` en Release (`83a4e669b`): con
ThinLTO, `ConfigurationGeneration::renderPick` guardaba un `PickItems` de
432 KiB en su propio marco y llamaba a `keep<definition>`, que guardaba otro.
Eran 865,8 KiB en un hilo de 512 KiB. Un marco mayor que la página de guarda
(16 KiB) se la salta: `sp` quedó en la región contigua de debajo, y el `bzero`
que pone a cero el búfer la fue pisando hacia arriba, unos 325 KiB, hasta tocar
la guarda.

Un marco solo se puede medir en el binario enlazado. `tools/stack-frames.py`
lee el desensamblado de un binario arm64: cada marco es lo que el prólogo resta
a `sp`. La pila más profunda de una función es su marco más el de la llamada
directa más honda. No ve las llamadas indirectas (ranuras de Qt,
`std::function`, `run()` virtual), y un hilo suele llegar a su trabajo por una
de ellas: medido desde su entrada, el hilo Lua daba 0,5 KiB también con el bug.
Por eso se mide desde cada función (`--entry . --min-depth`) y el hilo se lee en
el código. Ese método marca `renderPick` con 865,8 KiB en el binario anterior al
arreglo.

### Pilas

- **Hilo principal:** 8 MiB. Los ejecutables no fijan `stacksize` en
  `LC_MAIN`, así que manda el `ulimit -s` del entorno (8176 KiB en esta máquina).
- **Hilos secundarios:** 512 KiB (524 288 bytes medidos con
  `pthread_attr_getstacksize`). Es lo que reciben `std::thread`, `std::jthread`,
  `QThread` (el hilo `telar-lua`) y los de `QThreadPool` y `QtConcurrent`, porque
  nadie fija otro tamaño. `NameResolutions` lo fija a 512 KiB a propósito.

### Inventario

Release con ThinLTO, macOS ARM64, sobre `83a4e669b`. Funciones con un marco de
64 KiB o más, el hilo en que corren y la pila más profunda que alcanzan desde
ellas por llamadas directas:

| Binario | Función | Marco | Más profunda | Hilo (pila) |
| --- | --- | ---: | ---: | --- |
| `telar-gui` | `ActivityOrder<Memory>::write` | 323,2 KiB | 323,9 KiB | principal (8 MiB) |
| `telar-gui` | `main` | 235,3 KiB | 492,0 KiB | principal (8 MiB) |
| `telar-gui` | `Application::refreshAgents` | 208,2 KiB | 219,2 KiB | principal (8 MiB) |
| `telar-runtime` | `cli::runRuntime` | 1677,6 KiB | 1938,2 KiB | principal (8 MiB) |
| `telar-runtime` | `plugins::runWorker` | 421,7 KiB | 424,0 KiB | principal (8 MiB) |
| `telar-runtime` | `cli::runServer` | 340,0 KiB | 2278,2 KiB | principal (8 MiB) |
| `telar-runtime` | `redirect::Helper::plan` | 322,6 KiB | 322,6 KiB | principal (8 MiB) |
| `telar-runtime` | `cli::runTraffic` | 280,1 KiB | 671,5 KiB | principal (8 MiB) |
| `telar-runtime` | `traffic::Service::submit` | 257,1 KiB | 257,3 KiB | principal (8 MiB), desde el bucle de `Runtime` |
| `telar-runtime` | `TcpFlows::publish<…>` (3 instancias) | 257,1 KiB | 262,1 KiB | hilo de `traffic::Service` (512 KiB) |
| `telar-runtime` | hilo de un `ObservationWorker` | 188,1 KiB | 291,4 KiB | propio (512 KiB) |
| `telar-runtime` | `cli::runPluginWorker` | 160,6 KiB | 163,1 KiB | principal (8 MiB) |
| `telar-runtime` | `glyph.execute.register` (libghostty-vt) | 68,5 KiB | 68,8 KiB | ese `ObservationWorker` y el bucle de `Runtime` |
| `telar-runtime` | `redirect::Helper::run` | 67,7 KiB | 391,4 KiB | principal (8 MiB) |
| `telar-runtime` | `traffic::Service::observeFlow` | 65,1 KiB | 65,5 KiB | hilo del proxy (512 KiB), por la interfaz virtual |
| `telar-runtime` | `CaptureProducer::decodeBody` | 64,5 KiB | 97,2 KiB | un `ObservationWorker` (512 KiB) |
| `telar-runtime` | `checkpoint::Reader::read<…>` | 64,1 KiB | 82,4 KiB | principal (8 MiB) |
| `telar-runtime` | un miembro de `Runtime<…>` | 64,0 KiB | 177,7 KiB | principal (8 MiB) |

`telar` (la CLI) tiene siete marcos de entre 64,0 y 65,2 KiB. Su pila más
profunda es de 110,2 KiB en el hilo principal y de 64,1 KiB en el hilo de
`relayInput`. En `telar-gui`, desde el arreglo, `main` es la única función cuya
pila pasa de 384 KiB.

Ninguna anida por encima de la pila de su hilo. Los dos hilos secundarios más
cargados son el del `ObservationWorker` (291,4 de 512 KiB) y el de
`traffic::Service` (286,2 de 512 KiB). Ahí un segundo marco de 257 KiB
alcanzado por una llamada indirecta pasaría del límite. Cada una de las tres
instancias de `TcpFlows::publish` hace una sola llamada indirecta; el resto de
su camino está medido.

### `-Wframe-larger-than`

Se diagnostica en el enlace ThinLTO. Con el toolchain fijado (Clang 23.1.5), un
caso de dos unidades en el que solo la inserción entre ellas junta dos búferes
de 40 000 bytes no avisa al compilar ninguna. Al enlazar, ld64 y `ld64.lld`
escriben `stack frame size (80144) exceeds limit (65536) in function 'main'`.

No sirve como límite que rompa el build en macOS. El aviso lo emite el
manejador de diagnósticos de libLTO y el enlace termina con 0:
`-Werror=frame-larger-than`, al compilar o al enlazar, no cambia su gravedad, y
`-Wl,-fatal_warnings` de ld64 no lo ve. Con `ld64.lld -fatal_warnings` sí falla,
pero macOS enlaza con ld64. En Linux (`ld.lld --fatal-warnings`) no se ha
probado, y convertiría en error cualquier otro aviso del enlace. Además, un
límite único no distingue hilos: el hilo principal lleva marcos de 1677,6 KiB
que caben de sobra, y lo que importa son los hilos de 512 KiB. Se queda el
inventario, que se repite con `tools/stack-frames.py` cuando cambie el reparto
de cuerpos o de hilos.
