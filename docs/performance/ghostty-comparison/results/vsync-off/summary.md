# Ghostty y Telar

Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.

Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde a las medianas de las rondas independientes.

| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| single | Ghostty | 4 | 400 | 1.850 | 2.921 | 8.598 | 11.425 | [1.837, 1.853] |
| single | Telar GUI | 4 | 400 | 2.334 | 2.618 | 16.425 | 25.659 | [2.215, 2.401] |

Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es la media de las diferencias entre percentiles por ronda y el cociente es la media geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.

| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |
| single | Telar GUI | p50 | 4 | +0.458 | [0.396, 0.521] | 1.247 | [1.214, 1.281] |
| single | Telar GUI | p95 | 4 | -0.994 | [-3.631, 0.551] | 0.846 | [0.463, 1.250] |

IC mediante 10,000 remuestreos de rondas emparejadas, semilla 20260918. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.

Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. Los splits de Ghostty usan render targets independientes; el tamaño del target del pane principal puede diferir del de la escena completa de Telar.
