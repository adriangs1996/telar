# Reto: mantener un frame contiguo

La función que vamos a modificar es `solve`, en `problem.zig`. Solo necesita
arrays y metadatos. No conoce Telar, ventanas, fuentes, atlas, PTYs ni GPU.
Usa el tipo `Quad` real de Telar, de 80 bytes, para conservar el tamaño de los datos.

## El problema que estamos aislando

En el renderer hay trabajos diferentes:

1. Comprobar las celdas y actualizar la geometría que haya cambiado.
2. Recorrer las geometrías y producir los quads, respetando el orden de dibujo.
3. Componer un único array para la entrega nativa.
4. Subirlo al backend y dibujarlo.

Las cachés de panes intentaban evitar los dos primeros trabajos. Su mantenimiento
añadía copias, incluso cuando no volvíamos a aprovechar el contenido guardado.
El último experimento conservó los quads por pane, pero seguía copiando todos los
bloques al frame final en cada preparación.

Este reto aísla el tercer trabajo. **Recibimos los quads ya generados.** No estamos
midiendo cuánto cuesta producirlos. Tampoco son equivalentes la referencia de
este reto y la caché por celda de las campañas anteriores: la referencia aquí
es únicamente la concatenación completa de arrays.

## Enunciado

Recibes una lista ordenada de bloques. Cada bloque tiene:

- `id`: identidad estable y única dentro de la lista.
- `revision`: cambia cuando cambia cualquier byte de sus quads.
- `quads`: un array de quads ya calculados.

Mantén en `frame.output[0..frame.len]` la concatenación exacta de los bloques,
en el orden recibido. La salida anterior sigue disponible entre llamadas.

```zig
pub fn solve(blocks: []const Block, frame: *Frame) !Cost
```

Restricciones:

- Como máximo ocho bloques y una capacidad de salida fijada por el llamador.
- Ninguna asignación de memoria dentro de `solve`.
- La salida es propia y contigua; no puedes devolver referencias a los inputs.
- Los inputs no se solapan con la salida. Las revisiones son fiables.
- Puedes conservar metadatos propios entre llamadas, sin guardar punteros prestados.
- Mientras `frame.borrowed` sea verdadero, devuelve `error.FrameInFlight` sin escribir.
- Si falta capacidad o sobran bloques, devuelve error sin modificar salida ni estado.
- Los elementos posteriores a `frame.len` no forman parte del resultado.

En una integración real, una revisión tendría que cubrir también tema, geometría,
selección, cursor y recursos. El identificador de un frame de terminal por sí solo
no cumple ese contrato. En este reto lo garantiza el generador de inputs.

## Ejemplo

Cada número representa un Quad completo. En la vista se muestra su campo `x`;
la validación compara sus 80 bytes, no solo ese número.

```text
A, revisión 1: [1, 2, 3]
B, revisión 1: [8, 9]
Salida:       [1, 2, 3, 8, 9]
```

| Siguiente llamada | Salida correcta | Copias de la solución inicial |
| --- | --- | ---: |
| Todo igual | `[1,2,3,8,9]` | 0 quads |
| A cambia a `[11,2,3]`, revisión 2 | `[11,2,3,8,9]` | 3 quads |
| A crece a `[11,2,3,4]` | `[11,2,3,4,8,9]` | 6 quads |
| Orden B, A | `[8,9,11,2,3,4]` | 6 quads |

En el segundo caso solo cambió un valor, pero el contrato solo informa de que
cambió el bloque A. La solución inicial copia A entero. Para copiar menos habría
que inspeccionar sus elementos o recibir información de cambios más precisa.
Ninguna de las dos cosas es gratis ni forma parte del contrato actual.

## Qué contamos

Sean `P` los bloques, `Q` el total de quads y `K` los quads contenidos en bloques
que han cambiado, manteniendo tamaño y posición.

| Algoritmo | Visitas a metadatos | Quads copiados | Complejidad |
| --- | ---: | ---: | --- |
| `rebuild`, referencia | `2P` | `Q` | `O(P + Q)` |
| `solve`, forma estable | `3P` | `K` | `O(P + K)` |
| `solve`, cambia tamaño u orden | `3P` | `Q` | `O(P + Q)` |

Una visita es una iteración sobre la cabecera de un bloque; no es una instrucción
de CPU. La solución inicial conserva tres recorridos explícitos: validar,
comprobar la distribución y actualizar la salida. Se puede intentar fusionarlos.

Copiar `Q` quads escribe `80Q` bytes y lee otros `80Q` bytes de payload. No son
mediciones de tráfico DRAM ni de fallos de caché: la jerarquía de memoria puede
resolver esos accesos de formas distintas. También existen lecturas y escrituras
de metadatos que ese contador de payload no incluye.

Dos bloques de 1.600 quads suman 3.200 quads, o 256.000 bytes. La referencia los
copia siempre. La solución inicial copia cero si no cambia nada, 128.000 bytes si
cambia solo un bloque y 256.000 si cambian ambos.

## Objetivo siguiente

La solución inicial es deliberadamente simple: si cambia cualquier tamaño u
orden, reconstruye todo. Primer reto: conservar los bloques que siguen teniendo
el mismo contenido en la misma posición, aunque cambie otro bloque.

Por ejemplo, intercambia primero B y A y después haz crecer A. B sigue siendo
un prefijo válido: ¿puedes evitar volver a escribirlo? Los tests y la referencia
permiten cambiar `solve` y comprobar la respuesta.

Hay un límite que no debemos esconder: si cambia todo el payload y exigimos
una copia independiente y contigua, hay que escribir `Q` quads. No podemos
prometer `O(P)` en ese peor caso. Para eliminar esa materialización tendríamos
que cambiar el contrato: generar directamente en la salida o aceptar varios
bloques en el consumidor. Eso afectaría a la integración y requiere otro reto.

## Probar y medir

Solo el algoritmo, sin compilar Telar ni cargar bibliotecas gráficas:

```sh
zig test frame_challenge.zig
zig run -O ReleaseFast frame_challenge.zig
```

Vista interactiva:

```sh
zig build run-widget -Doptimize=ReleaseFast
```

- `N` o espacio: repetir el input actual.
- `1`: editar A; `2`: hacerlo crecer; `3`: encogerlo; `4`: intercambiar bloques.
- `R`: reiniciar.
- `B`: medir ambas funciones con dos bloques de 1.600 quads.

El modo sin ventana del mismo runner también está disponible:

```sh
zig build run-widget -Doptimize=ReleaseFast -- --bench
zig build test-widget
```

Cada caso del microbenchmark tiene 64 llamadas de calentamiento y 2.048 muestras.
Alternamos el orden de las funciones; mutaciones, comparación completa de bytes,
contadores y escritura de resultados quedan fuera del reloj. Ambas funciones
usan `noinline` y su salida se verifica en cada iteración para mantener trabajo
observable. No hay asignaciones dentro de ninguna de las dos funciones.

Estos tiempos son exploratorios y miden solo composición. Las comprobaciones
fuera del reloj también influyen en la temperatura de caché de la siguiente
iteración. No son latencias de Telar ni una prueba de mejora global. Los conteos
permiten razonar antes de interpretar diferencias pequeñas de nanosegundos.

El runner conserva únicamente la ventana, el input y la propiedad del frame.
Los laboratorios anteriores y su runner quedaron archivados como texto en
`docs/performance/persistent-pane-quads-experiment/source/`; sus informes y datos
siguen disponibles. Ya no forman parte del runner activo.
