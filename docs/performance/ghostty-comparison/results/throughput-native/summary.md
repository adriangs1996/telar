# Ghostty y Telar

Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.

Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde a las medianas de las rondas independientes.

| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| single | Ghostty | 6 | 6 | 7.288 | 7.358 | 7.359 | 7.359 | [6.066, 7.359] |
| single | Telar GUI | 6 | 6 | 2.456 | 4.560 | 5.103 | 5.238 | [1.794, 5.238] |

Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es la media de las diferencias entre percentiles por ronda y el cociente es la media geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.

| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |
| single | Telar GUI | p50 | 6 | -4.200 | [-4.964, -3.287] | 0.379 | [0.300, 0.501] |
| single | Telar GUI | p95 | 6 | -4.200 | [-4.964, -3.287] | 0.379 | [0.300, 0.501] |

IC mediante 10,000 remuestreos de rondas emparejadas, semilla 20260918. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.

El caudal termina al recibir la respuesta DSR del emulador después de procesar los bytes escritos en la PTY. Esa frontera precede a la finalización de GPU y no mide cuántos fotogramas se presentan.

| Caso | Aplicación | Carga | Ejecuciones | Mediana MiB/s | Rango MiB/s |
| --- | --- | --- | ---: | ---: | --- |
| single | Ghostty | ansi | 6 | 87.22 | [67.95, 91.23] |
| single | Ghostty | ascii | 6 | 82.52 | [53.41, 88.30] |
| single | Telar GUI | ansi | 6 | 8.18 | [7.82, 8.26] |
| single | Telar GUI | ascii | 6 | 8.13 | [7.58, 8.27] |

Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. Los splits de Ghostty usan render targets independientes; el tamaño del target del pane principal puede diferir del de la escena completa de Telar.
