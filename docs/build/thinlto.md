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

### Crecimiento desde la base del refactor

Las dos regresiones de marcos de ThinLTO (el SIGBUS de `gui-quick` y
`dcc40ec38`) tienen la misma forma: el enlazador inserta en una función un
cuerpo con locales grandes que solo corre en un caso raro, y desde entonces
cada llamada a esa función reserva el marco entero y todo lo que llama queda
más abajo en la pila. Tras el `fork()` de cada pane, cada página de pila que el
runtime vuelve a escribir cuesta un fallo de página.

Para buscarlas de forma directa se compilaron en Release la base del refactor
`d1ab27cb6` (sin ThinLTO) y `61b218258` (con ThinLTO), y se comparó con el
análisis de `tools/stack-frames.py` el marco de cada función de `telar-runtime`,
`telar` y `telar-gui`. Los nombres se emparejan desmangleados, sin el módulo al
que pertenecen y con las pilas de asignadores de la base
(`SynchronizedAllocator<BudgetAllocator<SystemAllocator>>`,
`BudgetAllocator<SystemAllocator>`) escritas como `ConcurrentMemory` y `Memory`;
lo que no casa así se compara por el nombre cualificado sin argumentos de
plantilla ni parámetros, contra el mayor marco de ese nombre en la base. Lo que
la función inserta son las llamadas directas de la base que ya no hace.

Han crecido 4 KiB o más 40 funciones de `telar-runtime`, 8 de `telar` y 39 de
`telar-gui`, contando las que no tienen pareja en la base. Una inserción solo
es una regresión cuando lo insertado es condicional: si la función lo llama
siempre, la base ya pagaba ese marco un nivel más abajo y la pila tocada es la
misma.

#### Arregladas

Las ocho del camino caliente con inserción condicional, como en `dcc40ec38`:
`[[gnu::noinline]]` en la declaración de lo insertado, sin mover cuerpos. Marcos
en bytes; la pila más profunda, por llamadas directas.

| Función | Base | Cabeza | Arreglo | Más profunda (cabeza → arreglo) | Lo insertado | Hilo | Camino |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| `StateProjection::prepare` | 80 | 24 112 | 80 | 39 280 → 19 984 | `WorkspaceService::publishList`, `AgentSnapshotBuilder::publish` (solo si cambiaron) | principal, bucle de `Runtime` | cada carril de cada escritura a un cliente |
| `Terminal::refresh` | 128 | 11 520 | 208 | 15 776 → 14 784 | `TextMetadataCapture::capture` (solo si cambian filas con enlaces) | principal; también el observador de panes | cada frame con el terminal sucio |
| `GraphicsSynchronizer::publish` | 192 | 10 528 | 192 | 11 008 → 11 120 | `stage` (solo si cambian las imágenes) | principal | cada pane adjunto en cada frame |
| `CommandZones::finishSequence` | 0 | 8 240 | 160 | 8 352 → 8 480 | `privateReport` (OSC 6973), `directoryReport` (OSC 7) | principal (`Pane::read`) y el observador de panes | cada OSC que imprime un pane, por byte de PTY |
| `traffic::Service::step` | 1 360 | 18 464 | dentro de la entrada del hilo, 1 904 | | `Service::read` (solo los pares listos) | hilo de `traffic::Service` (512 KiB) | cada vuelta de `poll` |
| `ProxyService::advance` | 112 | 4 208 | 256 | 29 744 → 25 792 | `ConnectHandshake::advance` (hasta responder al `CONNECT`) | hilo del proxy (512 KiB) | cada evento de un túnel |
| `CaptureProducer::decodeBody` | 160 | 66 032 | 512 | 99 536 → 66 400 | `decodeSmallFlate`, con su búfer de 64 KiB (solo flate con límite pequeño) | `ObservationWorker` de captura (512 KiB) | cada cuerpo capturado con codificación |
| `LuaTraffic::call` | 1 040 | 30 816 | 1 088 | 33 680 → 29 376 | `registerCallback`, `registerControl`, `decide` (una por llamada) | proceso del worker de plugins, principal | cada llamada de un plugin a la API de tráfico |

`ProxyService::advance` sigue insertando `ProxyConnection::advance`, que llama
siempre. Frente a la cabeza, el arreglo solo hace crecer la entrada del hilo de
`traffic::Service` (de 80 a 1 904 B), que se entra una vez. `telar` sale
idéntico byte a byte.

Medido en local, Release, en reposo, la cabeza contra la cabeza con el arreglo:

- `bench_runtime_probe.py` con una copia de la cabeza como A′: en tiempo,
  12 rondas, ninguna de las 11 cargas se separa de A′ (p de 0,166 a 0,862). En
  instrucciones y ciclos del runtime, 7 rondas, tampoco (p ≥ 0,085). Las dos
  cargas que ganan 1 de 7, `sparse` en instrucciones (1,0003) y `colors` en
  ciclos (1,049), tienen A′ en 1/7 y 3/7. Esta herramienta abre un pane y solo
  mide frames, así que no ve los fallos de página tras un `fork()`.
- `tools/client_queue`, escenario `server-cli`, como en `dcc40ec38`: dos series
  de 200 vueltas por lado en bloques intercalados, con el orden de los lados
  invertido en la segunda. La latencia de un frame desde que se encola hasta que
  se escribe, por la mediana de cada vuelta, baja de 2,84 a 2,68 µs (p = 5e-7) y
  de 2,85 a 2,75 µs (p = 5e-4). El carril `management` queda en 25,9 frente a
  26,0 µs (p = 0,47) en la primera serie y pierde de 25,4 a 26,7 µs (p = 0,024)
  en la segunda. `CreatePane` pierde en las dos, de 23,5 a 24,1 µs (p = 0,045) y
  de 23,6 a 24,6 µs (p = 0,004), y `OpenPane` en la segunda, de 28,6 a 30,1 µs
  (p = 0,001).
- Esa pérdida es colocación. Cae en el resto de `receive()`,
  `updateWriteInterest()` y el resto del lote de eventos (de 42 a 125 ns, dos
  tics del reloj), que no llaman a nada de lo arreglado. `clientEvent`,
  `receive`, `updateWriteInterest`, `writeClient`, `run`, `Kqueue::wait`,
  `Kqueue::readInterest`, `Connection::read` y `Connection::write` dan el mismo
  desensamblado normalizado en los dos binarios medidos, a 0x1164 bytes de
  distancia (`run`, en la misma dirección); solo cambian `publish` y
  `paneEvent`. Con `--faults`, 40 vueltas por lado, los fallos de página y de
  copia en escritura de cada tramo hasta `publish()` son los mismos o menos.

#### Se quedan

`telar-runtime`:

- **Entradas que se ejecutan una vez:** `cli::runTraffic` (15 520 → 286 784,
  inserta `runRedirect`; hilo principal del comando `traffic`), el constructor
  de `Runtime` (1 328 → 32 656), `traffic::control::Backend::start`
  (1 984 → 8 816) y las entradas de hilo (`__thread_proxy`) del
  `ObservationWorker` de procesos (48 → 192 640, pila más profunda 298 KiB de
  512), del `ObservationWorker` de descendientes (12 064), del servicio de
  control de tráfico (9 952), de tres `RequestWorker` (8 672, 7 840 y 7 808), de
  `ProxyService` (7 584) y de `WorkspaceGitProbe` (4 368). Su marco se reserva
  una vez por hilo.
- **Solo al parar:** `PaneObservationService::finish` (3 488 → 39 088).
- **Inserción incondicional:** `PaneMedia::process` (256 → 25 024, hilo de media)
  llama a `AtomicFrameFilter::feed` en cada evento de salida del lote, y la base
  ya pagaba sus 26 KiB en cada llamada; la pila más profunda baja de 184 a
  47 KiB.
- **Una petición concreta de un cliente**, no cada evento: las lambdas de
  `Runtime::dispatch` de `CompleteWords` y `RequestCommandSpec` (64 → 10 688,
  construyen un `WordRequest` de 10 KiB en cada llamada), `CreateWorkspace`
  (5 520), `CreateTab` (4 656) y `LaunchWorktree` (4 384), y
  `ExecutionService::request` (224 → 8 432, `telar exec`). Lo insertado corre
  en cada llamada, y la base lo pagaba un nivel más abajo.
- **Una vez por conexión:** `makeOwned<Http2EndpointConnection>` (1 200 → 7 008),
  en el proxy.
- **Sondas de git en workers, por intervalo:** `WorktreeGitProbe::observe`
  (5 600 → 10 208), `UnstagedComparison::scan` (4 320 → 8 816),
  `ObjectDatabase::open` (0 → 6 688), `StatusReader::readReferences`
  (0 → 4 304) y la lambda de `parseConfig` de `readUpstream` (4 112, sin pareja).
- **Configuración y plugins, al cargar:** `BasicActionValidator::commandTab`
  (624 → 4 880), la lambda de `eachField` de `CommandTabStorage` (10 320),
  `inspectPackage` (8 400) y `registerPackages` (6 544), estas tres sin pareja.
- **Sin pareja porque cambiaron de sitio, sin crecer:** `writeAsciiRun`
  (16 400) es la `Engine::ordinaryAscii` de la base (16 384, el mismo búfer de
  4096 codepoints); `ExecutionService::event` (16 400) vivía dentro de
  `Runtime::run` (19 584 en la base, 3 296 en la cabeza) y
  `CommandTrackerCore::resetObservation` (16 704) dentro de
  `PaneObserver::observe` (16 896 en la base, 544 en la cabeza).

`telar`: todos son comandos que se ejecutan una vez en el hilo principal
(8 MiB): `repository::run` (784 → 66 256), `MachineProfileCodec::parse`
(320 → 16 832), `config_receive::run` (352 → 16 752), `sessions::worktree`
(1 008 → 11 792), `machine::Logins::run` (1 040 → 11 088), `runMachine`
(10 784 → 20 368), `execution::run` (1 376 → 6 816) e `inspectPackage` (8 400,
sin pareja).

`telar-gui`, ninguna tiene inserción condicional en un camino por frame o por
evento:

- **Por frame, inserción incondicional:** la ranura de `beforeSynchronizing` de
  `Application::observeFrames` (0 → 18 464) llama a `prepareFrame` en cada
  frame (más profunda 18 912 → 18 976); la de `frameSwapped` (0 → 4 320) inserta
  `present` y `TerminalItem::presentFrame`, que corre para cada pane de cada
  frame (13,1 → 13,0 KiB hasta `refreshLinkHover`).
- **Por lectura de un proceso, inserción incondicional:** las ranuras de
  `readyRead` de `CommandProcess` (0 y 32 → 10 048) y de `RemoteBridge`
  (0 → 8 208) llaman siempre a `drain`. `CommandProcess::finish`
  (10 048 → 21 088) y la ranura de salida de `RemoteBridge` (0 → 8 208) corren
  cuando el proceso termina.
- **Por cambio de actividad, inserción incondicional:** `ActivityOrder::write`
  (228 528 → 331 008, hilo principal) inserta `emitForest`, que llama siempre;
  la más profunda baja de 350 a 332 KiB.
- **Configuración, en el hilo `telar-lua` (512 KiB):** el constructor de
  `ConfigurationGeneration` (128 → 28 592, la más profunda baja de 86,9 a
  55,5 KiB), `ConfigurationLoader::prepare` (384 → 7 744) y, sin pareja,
  `InputConfiguration::compile` (26 752), `ElementReader::box` (15 696) y la
  lambda de `eachField` (10 320).
- **Acciones del usuario o cambios de máquinas:** `Application::startPlugin`
  (112 → 13 424), `HostCommands::operator()` (0 → 10 688),
  `applyMachineProfiles` (160 → 10 528), `Session::executeCommand` (0 → 6 336),
  `openLink` (4 208 → 8 384), `MachineProfileCodec::parse` (320 → 16 832) y,
  sin pareja, `CommandOutput::execute` (16 480), `PathExpansion::expandWith`
  (12 352), `Session::openAnchoredFile` (8 352), `inspectPackage` (8 400),
  `registerPackages` (6 544) y `Session::descendPath` (5 184).
- **Una vez, en `QThreadPool`:** las tareas de `MachineProfilesSource::start`
  (10 624 → 22 832), `PluginWorker::start` (80 → 6 720) y
  `WindowFontCatalog::start` (336 → 5 184), y `makeOwned` de
  `PluginWorkerSnapshot` (128 → 6 672). `makeOwned` de `FontCache::Generation`
  (128 → 4 528) se entra solo al crear una generación.
- **Código generado o de terceros:** cinco `validateLookupSignatures` de
  `qmlcachegen` (96 → 4 432–4 512), al cargar el QML; en HarfBuzz, la creación
  de los aceleradores CFF (0 → 8 288 y 8 320, una vez por cara) y
  `hb_ot_draw_glyph` (272 → 4 816) y `hb_ot_get_glyph_extents` (0 → 4 608), que
  solo corren al rasterizar un glifo que no está en caché. No son declaraciones
  de telar.
