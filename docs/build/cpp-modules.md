# Migración C++ y build reproducible

## Inventario y decisión de arquitectura

Base de partida: `3306dc584df23dd0eadb844057d757683d7a77a2`.
El runtime y el cliente siguen siendo procesos y bibliotecas separados.

| Componente | Target | Dependencias propias | Interfaz final |
| --- | --- | --- | --- |
| base | `telar::base` | ninguna | módulos de texto, memoria y diagnósticos |
| cliente | `telar::client` | base | protocolo, codecs, serializadores, conexión |
| plataforma | `telar::platform` | base, cliente | POSIX y unidades de implementación |
| Lua | `telar::lua` | base, VM vendorizada | módulos de wrappers; VM sin migrar |
| plugins | `telar::plugins` | plataforma | manifiestos, paquetes, permisos |
| config | `telar::config` | Lua, plugins | opciones y validación |
| TLS | `telar::tls` | config, OpenSSL | certificados y trust |
| runtime | `runtime-core` | TLS, clipboard, VT, bibliotecas nativas | módulos por interfaz de componente |
| CLI | `cli-core`, `cli-launch` | TLS | módulos de argumentos, comandos y conexión |
| GUI | `gui-core`, auxiliares | config, VT, Qt | módulos de dominio; fronteras nativas separadas |
| auth | `telar-auth-daemon` | sistema | `main` sin API propia |
| WebSocket | `telar::websock` | base | módulos de framing y validación |

El grafo de interfaces migradas no tiene ciclos. Las interfaces `.cppm`
contienen las declaraciones y definiciones propias; no envuelven una copia
completa de la API de headers. Los headers de macros siguen siendo textuales.
Las declaraciones utilizadas por Objective-C++ deben conservar su frontera de
lenguaje, pues los BMI registran el modo del compilador. `moc` consume headers y
produce C++ que incluye esos headers: las clases Qt/QML conservan esa interfaz.
Los headers C, generados y vendorizados conservan su lenguaje y su propietario.

TBC conserva sus macros de anotación y la integración con el AST del linter;
EBNF consume ese contrato de anotaciones; sus algoritmos viven en los módulos
propios del lexer y del parser.

## Fuentes oficiales consultadas (2026-11-06)

- [CMake, módulos C++](https://cmake.org/cmake/help/v4.4/manual/cmake-cxxmodules.7.html):
  file sets, escaneo y ordenación nativa de dependencias, instalación de fuentes.
- [Clang, módulos estándar](https://clang.llvm.org/docs/StandardCPlusPlusModules.html):
  fragmento global para dependencias textuales y propiedad de declaraciones.
- [clangd, soporte experimental](https://clangd.llvm.org/features.html):
  requiere activar el soporte de módulos y una base de compilación coherente.
- [Qt, moc](https://doc.qt.io/qt-6/moc.html): entrada por headers, código generado.
- [LLVM 23.1.5](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.5),
  [CMake 4.4.5](https://github.com/Kitware/CMake/releases/tag/v4.4.5),
  [Ninja 1.13.2](https://github.com/ninja-build/ninja/releases/tag/v1.13.2).
  Se eligen releases estables; CMake 4.5 está en fase RC.

## Baseline antes de la migración

macOS ARM64 26, CMake 4.4.5, Homebrew LLVM/clangd 23.1.4,
Ninja 1.11.1.git.kitware.jobserver-1, Zig 0.17.0.

```sh
cmake -S dlls/telar-base -B .dev/modules/baseline-base -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++
cmake --build .dev/modules/baseline-base
ctest --test-dir .dev/modules/baseline-base --output-on-failure
```

Resultado: compila cada header; `telar-base-tests` pasa (1/1).
La primera configuración standalone del CLI, sin VT, falla correctamente por
`GHOSTTY_VT_INCLUDE_DIR`; no se considera fallo preexistente del código.
Se prepara el VT pineado en `.dev/modules/ghostty` para los siguientes checks.
Los logs locales se guardan en `.dev/modules/`, fuera del control de versiones.

## Implementación entregada

Las declaraciones y definiciones migradas viven en 162 interfaces reales, no en
headers incluidos desde un `export`. [modules.json](modules.json) registra cada
interfaz, su propietario actual y la correspondencia de 1021 interfaces de origen
con las unidades finales. `python3 tools/check-cpp-modules.py` comprueba propietarios,
proveedores, ausencia de ciclos y la explicación de cada header residual.

| Área | Interfaces finales | Organización |
| --- | ---: | --- |
| base | 5 | memoria, texto, diagnósticos, editores, historial |
| client, platform, Lua, plugins, config, TLS, WebSocket | 7 | un módulo por biblioteca |
| runtime | 73 | transporte, terminal, persistencia, proxy, tráfico y servicios |
| CLI | 17 | argumentos, conexión y familias de comandos |
| GUI | 58 | dominios y adaptadores C++; incluye una partición de vistas de fuentes |
| EBNF | 2 | lexer y parser |

Las agrupaciones respetan las dependencias entre componentes. Los servicios usan
unidades acotadas por dominio; las bibliotecas pequeñas tienen una fachada propia.
Esto evita tanto un único módulo de la aplicación como un BMI por cada pequeño
header. Las unidades `.cpp` que definen miembros fuera de clase son unidades de
implementación del módulo correspondiente. Sus cambios no necesitan recompilar
los importadores de la interfaz.

Los templates y funciones calientes permanecen visibles en `.cppm`. Las funciones
originalmente definidas dentro de una clase conservan `inline` explícito: en un
módulo con nombre esa propiedad ya no es implícita. No se han cambiado algoritmos,
formatos, límites ni el reparto runtime/cliente. GUI conserva `-ffp-contract=off`
para no alterar sus cálculos de representación al cambiar de unidad.

`cmake/cpp_modules.cmake` selecciona C++23, Ninja y el escaneo nativo de CMake,
registra `FILE_SET CXX_MODULES` públicos y aplica una variante coherente a todos
los proveedores e importadores. Debug activa `TELAR_DEBUG` y `TELAR_DIAGNOSTICS`;
Release puede activar `TELAR_DIAGNOSTICS`. `TELAR_SANITIZERS` instrumenta todo el
grafo C/C++ propio. Los nombres antiguos de opciones sanitizer siguen aceptándose.
Cada variante necesita su directorio de build; las macros del importador no
reconfiguran un BMI. No se usa `import std`: las dependencias estándar pertenecen
al fragmento global y proceden de la biblioteca estándar seleccionada.

### Fronteras textuales restantes

El inventario contiene 300 headers vivos, cada uno con su motivo concreto:

- Qt/moc y adaptadores que comparten sus declaraciones: `moc` necesita sus headers
  de clases y metatipos. El agregado generado se incluye desde una unidad C++ que
  CMake sí escanea, de modo que sus imports tienen ordenación nativa.
- ABI C y Objective-C++: clipboard, fuentes, memoria y tipos compartidos con `.mm`.
  Se verificó que importar un BMI C++ desde Objective-C++ produce un rechazo por
  incompatibilidad de modo de lenguaje en Clang 23.1.5. La clausura de tipos que
  cruza esa frontera permanece textual; el resto de cada dominio usa módulos.
  El test de clipboard del runtime se separa en C++ y un pequeño helper `.mm`.
- Especialización SIMD por importador: los tests escalar/vectorial necesitan
  recompilar esas funciones con macros distintas. El parser y sus tipos comunes
  conservan esa frontera, sin crear una segunda API completa.
- Contratos del preprocesador: macros de diagnósticos/traza y anotaciones TBC.
  El linter inspecciona expansiones y ubicaciones de origen; sus adaptadores del
  AST usan directamente el SDK de Clang con el que se construye la herramienta.
- Fixtures y utilidades de tests: includes locales, macros de aserción y fixtures
  de compilación deliberadamente válida o inválida. No son APIs de aplicación.

Los generadores de bindings, temas, paleta y tablas gráficas producen fragmentos
`.inc` de datos dentro de sus módulos propietarios. El código vendorizado conserva
sus headers y lenguaje. El auth daemon solo contiene un `main` vacío: no tiene
una API propia que justifique una interfaz de módulo artificial.

## Herramientas y dependencias desde un clon limpio

Los pins, URLs oficiales y SHA-256 están en `tools/toolchain/manifest.json`:
LLVM/clang/clangd 23.1.5, CMake 4.4.5, Ninja 1.13.2, Just 1.59.0 y Zig 0.17.0.
[Just 1.59.0](https://github.com/casey/just/releases/tag/1.59.0) es opcional para
los comandos directos; también lo instala el bootstrap para las recetas `just`.
Zig conserva la versión exigida por la receta fijada de Ghostty.

| Origen | Responsabilidad |
| --- | --- |
| SDK macOS | Xcode/Command Line Tools, linker, frameworks nativos y libc++ del SDK |
| SDK Linux | Python 3.9+, Git, make, compilador inicial, Perl, patch, flex, bison y herramientas de empaquetado |
| `tools/cpp bootstrap` | LLVM, CMake, Ninja y Just aislados en `.toolchain/` |
| `tools/cpp vt` | Zig verificado, checkout fijado de Ghostty y VT en caché privada |
| CMake gestionado | Qt, OpenSSL, SQLite, compresión, nghttp2, pcap, FreeType, HarfBuzz, Lua y demás bibliotecas ya fijadas |
| SDK de escritorio Linux | APIs de la sesión gráfica y del driver: X11/XCB, Wayland, xkbcommon, Fontconfig, EGL/OpenGL, Vulkan y D-Bus |

No se necesitan instalaciones de Qt, OpenSSL o fuentes de aplicación desde
Homebrew/apt. El SDK de escritorio Linux es la excepción nativa: Qt debe hablar
con el servidor gráfico, el driver y las fuentes instaladas por el sistema.
La lista reproducible para Ubuntu 24.04 está en
`packaging/release/install-linux-deps.sh`, de acuerdo con los
[requisitos oficiales de Qt para Linux](https://doc.qt.io/qt-6/linux-requirements.html).
El perfil headless desactiva clipboard nativo y GUI; no requiere ese SDK gráfico.

En macOS se usan las cabeceras libc++ del mismo SDK que la biblioteca del sistema,
con LLVM fijado como compilador. Usar las cabeceras libc++ del tarball LLVM con el
runtime Apple produjo símbolos ABI ausentes al enlazar Qt y se corrigió en el
toolchain generado. Linux selecciona libc++ del toolchain y enlaza explícitamente sus archivos
estáticos `libc++.a` y `libc++abi.a`, según la
[configuración de runtime de LLVM](https://libcxx.llvm.org/VendorDocumentation.html). En musl y hosts sin binario oficial compatible, el bootstrap compila
LLVM/libc++ desde los archivos verificados; reutiliza la receta OpenSSL existente
para HTTPS de CMake. Esa ruta necesita un SDK C/C++ inicial. El script Alpine de
release lo prepara. No se ha ejecutado esa ruta en esta máquina macOS ARM64.

Las descargas se verifican antes de publicarse y se rechazan entradas de archivo
que escapen del directorio de extracción. Los locks evitan publicar instalaciones
parciales. `.toolchain`, `.dependencies-cache`, `.qt-cache` y los directorios de
build son locales e ignorados por Git. Las recetas gestionadas siguen separando
cachés por fuente, receta, compilador, flags, arquitectura y SDK; ahora también se
incluye la versión de build del SDK de Apple. El wrapper revalida el SDK
seleccionado y regenera el toolchain cuando cambian su ruta o identidad; se
comprobó invalidando únicamente el marcador privado y verificando su restauración
y la reutilización posterior sin descargas.

### Comandos completos

Desde la raíz del repositorio, con Python 3.9+, Git y el SDK nativo disponibles:

```sh
# macOS: Xcode or Command Line Tools must provide xcrun and the SDK.
# Ubuntu 24.04 desktop: sudo packaging/release/install-linux-deps.sh
# Ubuntu 24.04 headless (development tools and SDK):
# sudo apt-get update -qq
# sudo apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
#   git python3 g++ make perl patch flex bison pkg-config file binutils
tools/cpp bootstrap
export PATH="$PWD/.toolchain/bin:$PATH"

tools/cpp configure runtime --config Debug
tools/cpp build runtime -- --parallel 3
ulimit -n 8192
tools/cpp test runtime

tools/cpp configure gui --config Debug -- -DTELAR_GUI_QT_JOBS=3
tools/cpp build gui -- --parallel 3
tools/cpp test gui
```

El primer configure de runtime/CLI/GUI prepara Zig y VT automáticamente; el de GUI
construye Qt antes de resolver sus paquetes. No abre una ventana ni instala la app.
Para tests GUI de integración, pasar
`-DTELAR_GUI_TEST_RUNTIME="$PWD/services/runtime-cpp/out/telar"` al configure: apunta
al CLI recién construido, que inicia su runtime hermano en el fixture privado.

```sh
# Use separate directories for each build variant.
tools/cpp configure runtime -B .dev/runtime-release --config Release \
  -- -DTELAR_RUNTIME_DISTRIBUTABLE=ON
tools/cpp build runtime -B .dev/runtime-release -- --target distributable-linkage --parallel 3
tools/cpp configure runtime -B .dev/runtime-sanitize --sanitizers
tools/cpp build runtime -B .dev/runtime-sanitize -- --parallel 3
tools/cpp test runtime -B .dev/runtime-sanitize

# Linux without graphical integration.
tools/cpp configure runtime -B .dev/runtime-headless --config Release --headless

# Standalone: the wrapper resolves each project dependency.
tools/cpp configure cli --config Release
tools/cpp build cli -- --parallel 3
tools/cpp test cli
tools/cpp configure base
tools/cpp build base -- --parallel 3
tools/cpp test base
python3 tools/check-cpp-package.py --build dlls/telar-base/out
```

También acepta `client`, `platform`, `lua`, `plugins`, `config`, `tls`, `websock`,
`auth`, `ebnf` y `tbc`. Las bibliotecas sin tests standalone se verifican compilando
su interfaz y mediante consumidores de runtime/CLI/GUI. Para EBNF/TBC/auth/WebSocket,
los presets equivalentes seleccionan el mismo toolchain: ejecutar primero el
bootstrap y usar el PATH anterior. `tools/cpp exec -- COMANDO` aplica ese entorno
sin modificar la configuración global del shell. `just runtime-build`,
`just gui-build`, `just editor` y las recetas lint usan la misma selección.

Base y WebSocket instalan fuentes de módulos y exportaciones CMake, sin BMI del
productor. Base comprueba que el consumidor use la misma configuración y versión
de compilador que el archivo estático instalado. El check de paquete (`--package base` o `--package websock`) instala en
un temporal, compila un consumidor externo, comprueba la generación de BMI local
y rechaza una configuración incompatible. No instala nada en el sistema.

### Editor y análisis

Configurar y construir el proyecto antes de abrir importadores. Sus `.clangd`
apuntan a `out/compile_commands.json`; para un build alternativo, pasar
`--compile-commands-dir=/ruta/al/build`. Usar:

```sh
.toolchain/bin/clangd --experimental-modules-support
python3 tools/check-cpp-editor.py --build dlls/telar-base/out \
  --file dlls/telar-base/tests/base_test.cpp
```

La configuración raíz elimina los flags de BMI del driver: clangd construye sus
propios BMI con sus opciones y descubre los proveedores en la base de compilación.
En los importadores que mezclan tipos ABI textuales e imports, un `static_assert`
bajo `__clangd__` impide separar esos dos conjuntos en el preámbulo PCH. Sin esa
medida, esta versión presenta errores de fusión de declaraciones estándar que el
compilador real no presenta. El guard no existe en la compilación de producción.
El check LSP abre el archivo, exige cero diagnósticos de error y pide navegación a
la definición del símbolo en su `.cppm`; no se limita a comprobar un exit code.
El soporte de módulos de clangd sigue siendo experimental. La primera carga de
los importadores grandes tarda varios minutos al construir su caché; el check
acepta `--timeout 600` para esos casos. No se afirma una mejora de tiempo respecto
al parser de headers anterior.

Los targets lint y format incluyen `.cppm` y conservan las exclusiones de fixtures
intencionalmente inválidos. Para clang-tidy, construir antes los proveedores de
módulos referenciados por la base de compilación.

## CI y release

Las CI de runtime y GUI usan la acción local `cpp-toolchain`, el manifiesto y las
mismas recetas. Runtime se ejecuta en PR y main, con macOS ARM64 y Linux x86_64 /
ARM64, Debug con sanitizers y Release. GUI tiene matriz macOS/Linux Debug/Release,
Qt privado y checks de aislamiento. Los filtros incluyen módulos, herramientas,
recetas y el toolchain; las claves de caché incluyen su identidad.

Los scripts de release usan `tools/cpp` y mantienen los checks de linkage y el
perfil musl headless. La imagen Alpine está fijada por digest. El build LLVM desde
fuentes permite conservar el perfil estático, sin convertirlo en un binario que
necesite libc++ instalada en el servidor. Los pasos posteriores de firma,
publicación y Homebrew no se han ejecutado ni alterado para esta verificación.

Estas matrices y rutas Linux/Intel no se han ejecutado aquí. Editar y revisar su
configuración no equivale a CI verde. No se ha lanzado CI remota.


## Verificación ejecutada en Personal

Entorno final: macOS ARM64, SDK 27.2 (`26B118`), LLVM/clang/clangd 23.1.5,
CMake 4.4.5, Ninja 1.13.2, Zig 0.17.0 y Just 1.59.0. El renderer del paquete
se compiló con Rust 1.93.1, el pin existente de release, instalado únicamente en
`.toolchain/rustup` / `.toolchain/cargo`. No se cambió el Rust global.

El baseline de runtime compiló `runtime-tests`, `tls-tests`, `hook-tests`,
`event-loop-tests` y `diagnostics-tests`. Cuatro pasaron inicialmente; runtime
falló al pedir `F_DUPFD` desde 4096 por el límite de descriptores de la shell.
Repetido con `ulimit -n 8192`, pasó también. No se asumió un fallo preexistente.
El baseline nativo completo de GUI no se terminó antes de migrar. Para investigar
la integración ampliada se reconstruyeron después runtime/CLI y `gui-quick-test`
del commit original en una copia aislada, con el mismo toolchain y Qt gestionado. Los logs de esta sesión están en `.dev/modules/`, ignorados.

| Comprobación | Resultado |
| --- | --- |
| Bootstrap: hash, path traversal, symlinks, publicación ZIP y reutilización offline | 6/6; actualización de identidad SDK comprobada |
| Inventario y grafo | 162 interfaces; DAG sin ciclos; 300 fronteras explicadas |
| Base Debug, probes individuales de interfaces y headers ABI | build y 1/1 |
| Consumidores externos de base y WebSocket instalados en temporales | importa fuentes, genera BMI local y rechaza configuración incompatible |
| Runtime Debug completo | 50/50 |
| CLI standalone Release | 12/12 |
| Runtime Release limpio, ejecutables y linkage distributable | build, linkage de los tres ejecutables y 5/5 tests principales |
| Runtime Debug ASan + UBSan, clipboard headless | build de runtime/CLI y 5/5 tests principales |
| GUI Debug nativa con Qt privado | build completo; 134/135 targets CTest; el fallo restante se reproduce en el código original (detalle abajo) |
| GUI Release nativa limpia | build de GUI y command helper |
| GUI headless Debug ASan + UBSan | core, configuración y efectos de sesión: 3/3 |
| Auth y WebSocket standalone Debug ASan + UBSan | 1/1 cada uno |
| EBNF Debug | 93/93 |
| TBC Debug y contratos/spec | 15/15; format-check y lint completos pasan |
| Standalone client, platform, Lua, plugins, config y TLS en Release | seis configuraciones y builds completos |
| Qt: integridad, parche, aislamiento y prefijo real de GUI | 6/6, sin skip |
| clangd LSP: base, runtime, GUI y unidad de implementación | cero errores y navegación a `.cppm` en los cuatro casos |
| clang-tidy de implementación platform y reloj GUI | sin errores; warnings de estilo en platform |
| Just, presets y workflows | Just parsea; JSON y YAML parsean; shell scripts pasan revisión sintáctica |

Los builds limpios finales de aplicación se hicieron desde directorios nuevos:

```sh
tools/cpp configure runtime -B .dev/modules/runtime-clean-release --config Release \
  -- -DTELAR_RUNTIME_DISTRIBUTABLE=ON
tools/cpp build runtime -B .dev/modules/runtime-clean-release -- --parallel 3 \
  --target distributable-linkage runtime-tests tls-tests hook-tests event-loop-tests diagnostics-tests
ulimit -n 8192
tools/cpp test runtime -B .dev/modules/runtime-clean-release \
  -- -R '^(runtime-tests|tls-tests|hook-tests|event-loop-tests|diagnostics-tests)$'

tools/cpp configure gui -B .dev/modules/gui-clean-release --config Release \
  -- -DBUILD_TESTING=OFF -DTELAR_GUI_QT_JOBS=3
tools/cpp build gui -B .dev/modules/gui-clean-release \
  -- --target telar-gui telar-gui-command --parallel 2
```

Estos builds reutilizan únicamente dependencias de las recetas verificadas; sus
objetos y BMI propios empiezan vacíos. Debug se construyó en
`.dev/modules/runtime-final-debug` y `.dev/modules/gui-final-debug`, y los builds
sanitizados en directorios `*-final-sanitize`. Se construyeron todos los targets
Debug antes de ejecutar CTest, no solo los tests seleccionados en CI.

La comprobación incremental usa `runtime-core`: un build sin cambios queda sin
trabajo; añadir y restaurar un comentario en
`dlls/telar-platform/src/pipe_process.cpp` recompila únicamente su objeto y archivo
estático; editar y restaurar la interfaz `platform.cppm` recompila sus consumidores
en runtime; la última repetición vuelve a quedar sin trabajo. Se restauraron los
bytes originales. Registro: `incremental-final.log` e `incremental-result.log`.
No se compararon tiempos equivalentes con el baseline ni se promete una mejora.

El tarball Linux x86_64 de LLVM se descargó y verificó localmente para inspeccionar
su SDK, sin ejecutar binarios Linux. Se comprobó la existencia de los archivos
estáticos de libc++ y el ABI de `libclang-cpp.so`: este SDK usa libstdc++.
Por eso TBC standalone en Linux usa el ABI C++ del SDK GNU para su herramienta AST;
las anotaciones incluidas desde EBNF conservan libc++ del proyecto padre. Esa
excepción pertenece a una herramienta de desarrollo, no añade una biblioteca de
sistema a los ejecutables de aplicación. No sustituye una ejecución de CI Linux.

El launcher macOS también es un target CMake (`telar-gui-launcher`) que importa
su módulo y usa el SDK y flags seleccionados; el packager copia ese ejecutable.
Se reserva espacio para reescribir los load commands de Mach-O durante el deploy
de Qt. Ya no se compilan fuentes modularizadas mediante un comando suelto que
pierda el grafo de imports o la biblioteca estándar.

### Resultado de la integración GUI ampliada

Con `TELAR_GUI_TEST_RUNTIME` apuntando al CLI Debug recién construido se registran
135 targets CTest. Los 133 tests de la primera pasada y `gui-suggestion-controls`
pasan. `gui-quick` llega al final: 137 casos pasan, uno falla y otro se omite porque
la minimización nativa requiere un plugin de sistema de ventanas (se usó
`QT_QPA_PLATFORM=offscreen`). No se presenta esta ejecución como completamente verde.

El único caso que falla es `configuredGroupKeyboardActions`, en
`verifyGroupPaneHeaderFocus`: encuentra cero etiquetas `paneProgram` donde espera
una. Se reprodujo exactamente el mismo fallo en `3306dc584`, con GUI y runtime
originales, toolchain 23.1.5 y el mismo Qt. La copia se obtuvo mediante `git archive`
en `.dev/modules/baseline-original`; sus fuentes C++/QML permanecen originales.
Solo se reutilizó el helper de identidad de caché del SDK para compartir las
mismas dependencias verificadas. Logs: `gui-group-baseline.log` y
`gui-group-isolated.log`. No se cambió la UI ni se ocultó esa aserción.

La prueba de cierre secuencial inicialmente expuso una carrera de sincronización:
una proyección puede reflejar una pane menos antes de que se procese el acuse
que permite otra operación. El test ahora espera `requestsPending() == false`
antes de emitir el siguiente cierre. Conserva la comprobación del número de panes
y pasa con el runtime migrado; no se añadió una espera temporal fija ni cambió el
comportamiento de producción. Toda la instrumentación de investigación se retiró.

Reproducción del caso residual y de la suite:

```sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  TELAR_GUI_TEST_RUNTIME="$PWD/.dev/modules/runtime-final-debug/telar" \
  PATH="$PWD/.dev/modules/runtime-final-debug:$PATH" \
  .dev/modules/gui-final-debug/gui-quick-test configuredGroupKeyboardActions

tools/cpp test gui -B .dev/modules/gui-final-debug -- --parallel 2
```

### Empaquetado macOS privado

El candidato `.dev/modules/Telar-modules-final.app` se generó con el runtime y GUI
Release anteriores, Qt gestionado y el renderer Rust. El auditor valida los 81
objetos Mach-O, sus frameworks/plugins y sus referencias; `codesign --verify
--deep --strict` pasa con firma ad hoc. El check de linkage de runtime, CLI,
config-check y renderer acepta únicamente bibliotecas/frameworks del sistema.
El paquete conserva licencias y manifiesto. No se abrió ni instaló.

Para reproducirlo desde el checkout con `rustup` disponible como herramienta de
SDK, usando un directorio de salida nuevo:

```sh
export RUSTUP_HOME="$PWD/.toolchain/rustup" CARGO_HOME="$PWD/.toolchain/cargo"
rustup toolchain install 1.93.1 --profile minimal --no-self-update
cargo +1.93.1 build --release --locked \
  --manifest-path tools/diagram-renderer/Cargo.toml --target-dir .dev/modules/renderer-target
tools/cpp exec -- cmake --install .dev/modules/runtime-clean-release \
  --prefix "$PWD/.dev/modules/package-prefix"
install -m 755 .dev/modules/renderer-target/release/telar-diagram-renderer \
  .dev/modules/package-prefix/bin/telar-diagram-renderer
python3 services/gui-cpp/tools/package_macos.py \
  --build .dev/modules/gui-clean-release --runtime-prefix .dev/modules/package-prefix \
  --output .dev/modules/Telar-modules-final.app
codesign --verify --deep --strict .dev/modules/Telar-modules-final.app
```

### Límites de la verificación

No se ejecutaron Linux, musl, ARM64 Linux ni macOS Intel; tampoco el bootstrap
LLVM desde fuentes. Se revisaron sus pins, recetas, SDK y configuración, con la
limitación anterior. El caso GUI residual anterior queda fuera de los cambios funcionales autorizados.
La primera entrega verificó perfiles y unidades representativas de runtime/GUI,
además del lint completo de TBC. El seguimiento descrito debajo ejecuta el lint
completo de runtime; el de GUI sigue sin ejecución completa.
La primera carga de módulos grandes en clangd sigue teniendo un coste de caché
alto y su soporte es experimental. No se ha medido rendimiento de ejecución para
atribuir una mejora a la migración; los algoritmos calientes y sus oportunidades
de inline permanecen en las interfaces.

No se instaló ni abrió la aplicación candidata, no se usó otra máquina para ejecutar builds,
no se reinició el Telar activo y no se hizo merge, push ni se lanzó CI remota.

## Correcciones de tooling posteriores a la revisión

El encargo de seguimiento corrige la preparación de `runtime-lint` y la cobertura
`.cppm` del formatter de EBNF. No cambia código de aplicación ni el fallo GUI
`configuredGroupKeyboardActions` ya reproducido en el commit original.

`just runtime-lint [jobs] [directory]` configura el proyecto y llama al script
común. Este refresca primero el manifiesto Ninja, lee la base de compilación y
selecciona una sola vez las unidades C++ de runtime, CLI y `telar-platform/src`,
incluidas las herramientas bajo `tools`, conservando la exclusión de tests.
Construye sus targets de objeto existentes: CMake/Ninja resuelven los proveedores,
generadores y BMI de cada contexto y crean los `.modmap` antes de clang-tidy.
El runner recibe exactamente los archivos preparados, escapados como expresiones
regulares. Usa las herramientas del SDK del compilador; los errores de build y
análisis se propagan. No depende de un build previo ni ejecuta tests.

```sh
# Run from the repository root; the directory starts empty.
tools/cpp exec -- just runtime-lint 3 "$PWD/.dev/tooling-fix/runtime-lint"

# The same preparation is available through the direct script entry point.
tools/cpp configure runtime -B .dev/runtime-lint --config Debug
tools/cpp exec -- cmake -DJOBS=3 \
  -DRUNTIME_BUILD_DIRECTORY="$PWD/.dev/runtime-lint" \
  -P services/runtime-cpp/cmake/lint.cmake

python3 -m unittest discover -s tools/tests -p 'test_cpp_*.py' -v
```

La ejecución real en macOS ARM64 comenzó sin objetos ni BMI en
`.dev/tooling-fix/runtime-lint`. Preparó los 112 contextos seleccionados, incluidos
los de herramientas, con sus modmaps y 101 artefactos de módulos. Los 152 contextos
de tests de esa base de compilación quedaron sin compilar. Clang-tidy analizó los 112 archivos y el punto de entrada `just runtime-lint`
terminó con retorno 0. El perfil sigue emitiendo advertencias; no se ignoran sus
errores ni se presenta como un análisis sin advertencias. Todos los modmaps
seleccionados existen. Repetir sus targets de objeto da `ninja: no work to do` y
conserva sus timestamps (`incremental-preparation.log`). El log completo está
en `.dev/tooling-fix/runtime-lint.log`; los artefactos aislados del coordinador
`.dev/review-modules-*` no se usaron como build de verificación.

Las nueve regresiones de tooling pasan: seis de bootstrap, dos de formato y una
de preparación de lint. Esta última compila un grafo mínimo de módulos con
cabecera generada, importador y herramienta `EXCLUDE_FROM_ALL`; deja sin compilar
un test deliberadamente inválido. La segunda ejecución conserva los objetos sin
recompilar; al añadir otra herramienta, el script actualiza la base y la prepara
y analiza sin configurar manualmente. También comprueba rutas con `+` y un
ancestro llamado `tests`, y usa el alias del compilador en `.toolchain/bin`.
Los tests no descargan ni construyen toolchains: el caso
nativo usa el SDK ya preparado y se omite si falta. CI descubre ahora los tres
archivos `test_cpp_*.py`.

Se repitieron las regresiones contra los scripts anteriores a estas correcciones:
las dos de formato y la de lint fallan. En la de lint solo se adaptó la selección
del directorio temporal; sin preparación, el análisis sigue fallando por modmaps
y módulos ausentes. Registro: `.dev/tooling-fix/counterfactual.log`.

EBNF delega en el helper de TBC para compartir descubrimiento, invocación y
exclusiones de builds/vendor/generados. Tanto `format` como `format-check` reciben
los `.cppm`. Se verificó además con clang-format 23.1.5 sobre una copia pequeña:
el check falla antes de formatear, `format` modifica la interfaz y el check
posterior pasa; el archivo de vendor queda intacto.

El `format-check` real de EBNF informa 529 diagnósticos de estilo en 14 archivos:
503 corresponden a `lexer.cppm` y `parser.cppm`, ahora cubiertos. Los otros 26 en
12 archivos también se reproducen con el script anterior. Se conserva el retorno
de error y no se hace un reformat masivo. Logs: `ebnf-format-check.log`,
`ebnf-format-before.log` y `format-real.log`, bajo `.dev/tooling-fix`.

Esta corrección no ejecuta Linux, musl, Intel ni CI remota. Tampoco instala ni
reinicia el Telar activo; la integración local en `overhaul` queda a cargo del
coordinador, sin merge ni push desde esta rama.
