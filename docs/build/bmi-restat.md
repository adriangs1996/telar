# Launcher que conserva el BMI (P0.4): descartado

Idea: compilar cada unidad de interfaz con el BMI apuntando a un fichero temporal y sustituir el `.pcm` solo si cambian los bytes. CMake ya marca con `restat = 1` cada edge de su dyndep que produce un BMI, así que, si el `.pcm` conserva su mtime, Ninja no recompila los importadores.

El launcher funciona, pero no corta la cascada en los dos casos que importan (un comentario y un cuerpo no inline en un hub), porque en esos casos el BMI cambia de verdad. Se descarta. El código medido está en `bf0f73fd1` (`tools/bmi-restat` y la opción `TELAR_BMI_RESTAT` en `cmake/cpp_modules.cmake`), y el commit siguiente lo retira.

## Medición

Árbol `src/runtime-cpp` (runtime y CLI) en Debug, macOS arm64 con 8 núcleos y 16 GiB (4 compilaciones en paralelo), LLVM 23.1.5, CMake 4.4.5 y Ninja 1.13.2, sobre `82dfdddac`. El build completo compila 314 unidades. Cada caso parte de un árbol compilado y cuenta las líneas `Building CXX object` que ejecuta Ninja.

Ninguno de los dos hubs tiene funciones no inline: `telar.base.memory` solo tiene plantillas y funciones `inline`, y `telar.client.protocol` reexporta una cabecera textual. Para el caso "cuerpo no inline" se añadió al final de cada hub, solo durante la medición, una función exportada no inline `int …RestatProbe(int value) { return value + 1; }`, y la edición cambia `+ 1` por `+ 2`, que no altera la longitud del fichero. El comentario editado es el mismo en los dos hubs (línea 28 de `memory.cppm`, línea 7 de `protocol.cppm`) ("Owned textual headers stay…" → "Owned project textual headers stay…"). Las tres ediciones se aplican una detrás de otra.

| Hub | Cambio | Sin launcher | Con launcher |
| --- | --- | --- | --- |
| `telar.base.memory` | `touch` (mtime, mismo contenido) | 257 unidades, 102 s | 1 unidad, 2,7 s |
| `telar.base.memory` | comentario | 257 unidades, 67 s | 257 unidades, 64 s |
| `telar.base.memory` | cuerpo no inline | 257 unidades, 62 s | 257 unidades, 66 s |
| `telar.client.protocol` | `touch` | 221 unidades, 56 s | 1 unidad, 2,7 s |
| `telar.client.protocol` | comentario | 221 unidades, 58 s | 221 unidades, 61 s |
| `telar.client.protocol` | cuerpo no inline | 221 unidades, 57 s | 221 unidades, 62 s |

Los tiempos son de una sola ejecución: el primer caso tardó 102 s y las demás filas con 221 o 257 unidades, entre 56 y 67 s. El coste del launcher es arrancar Python en cada compilación de un target con módulos: unos 35 ms por invocación, medidos con la máquina compilando.

## Por qué cambia el BMI

Clang 23 ya emite el BMI reducido por defecto con `-fmodule-output` (el driver pasa `-fmodules-reduced-bmi`). Aun así, con un módulo de prueba de una función:

- `touch` del fuente: BMI idéntico. El BMI no guarda el mtime.
- Comentario de la misma longitud: BMI idéntico.
- Comentario más largo, en medio o al final del fichero: BMI distinto. Las posiciones del BMI son offsets en bytes del fichero.
- Cuerpo de una función no inline exportada, aunque mantenga la longitud (`x + 1` → `x + 2`): BMI distinto. `llvm-bcanalyzer -dump` muestra que solo cambia un operando de 32 bits del registro `DECL_FUNCTION` de esa función, un valor que depende del cuerpo.
- Cuerpo de una función miembro de una clase exportada: BMI distinto.

Por tanto, el launcher solo ayuda cuando un fichero de interfaz se reescribe sin cambiar de contenido: `git stash` y `git stash pop`, cambiar de rama y volver sin compilar en medio, o una herramienta que reescribe ficheros sin cambiarlos. Es un caso real pero raro, y no justifica pasar cada compilación con módulos por un proceso más.

## Qué corta la cascada entonces

Sacar los cuerpos de las interfaces (P9.x): un cambio en una unidad de implementación no reescribe ningún BMI y ya no recompila importadores. Un comentario en una interfaz seguirá recompilando a sus importadores con o sin launcher, mientras Clang guarde offsets en bytes.
