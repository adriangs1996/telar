# Build de C++

## Herramientas y dependencias desde un clon limpio

Los pins, URLs oficiales y SHA-256 están en `tools/toolchain/manifest.json`:
LLVM/clang/clangd 23.1.5, CMake 4.4.5, Ninja 1.13.2, Just 1.59.0 y Zig 0.17.0.
[Just 1.59.0](https://github.com/casey/just/releases/tag/1.59.0) es opcional para
los comandos directos; también lo instala el bootstrap para las recetas `just`.
Zig conserva la versión exigida por la receta fijada de Ghostty.

| Origen | Responsabilidad |
| --- | --- |
| SDK macOS | Xcode/Command Line Tools, linker y frameworks nativos |
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

macOS y Linux compilan contra libc++ del toolchain y enlazan explícitamente sus
archivos estáticos `libc++.a` y `libc++abi.a`, según la
[configuración de runtime de LLVM](https://libcxx.llvm.org/VendorDocumentation.html).
`import std` necesita el módulo `std` que corresponde a esas cabeceras; el SDK de
Apple no lo incluye y trae otra versión de libc++. Mezclar cabeceras del tarball
con el runtime de Apple dejaba símbolos ABI sin resolver al enlazar Qt, por eso
el runtime también es el del toolchain. En macOS, libSystem carga además la libc++
del sistema: los archivos se cargan con `-load_hidden` para que dyld no fusione
los `operator new`/`delete` débiles de la copia estática con los del sistema; sin
eso, la asignación tipada aborta antes de que libc++ se inicialice. En musl y hosts sin binario oficial compatible, el bootstrap compila
LLVM/libc++ desde los archivos verificados; reutiliza la receta OpenSSL existente
para HTTPS de CMake. Esa ruta necesita un SDK C/C++ inicial. El script Alpine de
release lo prepara.

Las descargas se verifican antes de publicarse y se rechazan entradas de archivo
que escapen del directorio de extracción. Los locks evitan publicar instalaciones
parciales. `.toolchain`, `.dependencies-cache`, `.qt-cache` y los directorios de
build son locales e ignorados por Git. Las recetas gestionadas siguen separando
cachés por fuente, receta, compilador, flags, arquitectura y SDK; ahora también se
incluye la versión de build del SDK de Apple. El wrapper revalida el SDK
seleccionado y regenera el toolchain cuando cambian su ruta o identidad.

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

tools/cpp configure dev -- -DTELAR_GUI_QT_JOBS=3
tools/cpp build dev -- --parallel 3
ulimit -n 8192
tools/cpp test dev
```

Un solo árbol, `out/<preset>`, construye las bibliotecas, el runtime, el CLI, la GUI
y el daemon de auth; los presets de `CMakePresets.json` son `dev`, `release`, `dist`
(runtime y CLI para distribución), `sanitize` y `ci`, y `-DTELAR_BUILD_{RUNTIME,CLI,GUI,AUTH}=OFF`
deja fuera un proceso. Los programas de cada proceso quedan en
`out/<preset>/src/<proceso>`. El primer configure prepara Zig y VT
automáticamente y construye Qt antes de resolver sus paquetes. No abre una ventana
ni instala la app. Para tests GUI de integración, pasar
`-DTELAR_GUI_TEST_RUNTIME="$PWD/.dev/bin/telar"` al configure, como hace `just`:
apunta al CLI recién construido, que inicia su runtime hermano en el fixture privado.

```sh
# Each preset builds into its own tree.
tools/cpp configure dist
tools/cpp build dist -- --target distributable-linkage --parallel 3
tools/cpp configure sanitize
tools/cpp build sanitize -- --parallel 3
tools/cpp test sanitize

# Linux without graphical integration.
tools/cpp configure release -B .dev/runtime-headless --headless -- -DTELAR_BUILD_GUI=OFF

# One process, its libraries and tests. Every case is a test of its own: a domain's carry
# LABELS <process>.<domain>, a library's lib.<library>, end-to-end checks <process>.e2e.
tools/cpp build dev -- --target src/cli/all
tools/cpp test dev -- -L '^cli\.'
tools/cpp build dev -- --target telar-base telar-base-tests
tools/cpp test dev -- -L '^lib\.base$'
python3 tools/check-cpp-package.py --build out/dev
```

`tools/cpp configure tbc` configura el linter, que sigue siendo un proyecto aparte.
Las bibliotecas sin tests propios se verifican compilando su interfaz y mediante
consumidores de runtime/CLI/GUI. TBC usa sus propios presets con el mismo
toolchain: ejecutar primero el bootstrap y usar el PATH anterior. `tools/cpp exec -- COMANDO` aplica ese entorno
sin modificar la configuración global del shell. `just runtime-build`,
`just gui-build`, `just editor` y las recetas lint usan la misma selección.

Base instala fuentes de módulos y exportaciones CMake, sin BMI del
productor. Base comprueba que el consumidor use la misma configuración y versión
de compilador que el archivo estático instalado. El check de paquete instala en
un temporal, compila un consumidor externo, comprueba la generación de BMI local
y rechaza una configuración incompatible. No instala nada en el sistema.

### Editor y análisis

Configurar y construir el árbol antes de abrir importadores (`just editor`). El
`.clangd` de la raíz apunta a `out/dev/compile_commands.json`; para otro árbol,
pasar `--compile-commands-dir=/ruta/al/arbol`. Usar:

```sh
.toolchain/bin/clangd --experimental-modules-support
python3 tools/check-cpp-editor.py --build out/dev \
  --file lib/base/tests/base_test.cpp
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
acepta `--timeout 600` para esos casos.

Los targets lint y format incluyen `.cppm`. lint analiza cada fuente con el
`.clang-tidy` más cercano, el perfil de su proyecto, y deja fuera las que no tienen
ninguno; antes de analizar, construye los proveedores de módulos y las cabeceras
generadas que lee la base de compilación. `just lint` y `just analyze` construyen antes
`tbc-tidy-scope.so`, el plugin de clang-tidy de `lib/tbc`: limita lo que recorre cada
check a lo que la unidad parsea ella misma, sin los módulos que importa, que se
analizan con la unidad que los define. Sin el plugin el resultado sobre el código de
cada unidad es el mismo y el análisis tarda varias veces más; `check.cmake` lo avisa
cuando no lo encuentra o clang-tidy no lo carga. Las fixtures que no se compilan no están en
la base y quedan fuera de lint.

## CI y release

Las CI de runtime y GUI usan la acción local `cpp-toolchain`, el manifiesto y las
mismas recetas. Runtime se ejecuta en PR y main, con macOS ARM64 y Linux x86_64 /
ARM64, Debug con sanitizers y Release. GUI tiene matriz macOS/Linux Debug/Release,
Qt privado y checks de aislamiento. Los filtros incluyen módulos, herramientas,
recetas y el toolchain; las claves de caché incluyen su identidad.

Los scripts de release usan `tools/cpp` y mantienen los checks de linkage y el
perfil musl headless. La imagen Alpine está fijada por digest. El build LLVM desde
fuentes permite conservar el perfil estático, sin convertirlo en un binario que
necesite libc++ instalada en el servidor.
