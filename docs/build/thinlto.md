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
