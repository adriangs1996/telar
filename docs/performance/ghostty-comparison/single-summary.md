# Ghostty y Telar

Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.

Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde a las medianas de las rondas independientes.

| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| single | Ghostty | 6 | 1200 | 6.904 | 18.137 | 24.496 | 43.344 | [2.230, 12.602] |
| single | Telar GUI | 6 | 1200 | 2.468 | 18.775 | 27.775 | 46.854 | [2.276, 8.306] |
| single | Telar TUI + Ghostty | 6 | 1200 | 10.319 | 23.974 | 33.928 | 43.824 | [2.328, 14.728] |

Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es la media de las diferencias entre percentiles por ronda y el cociente es la media geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.

| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |
| single | Telar GUI | p50 | 6 | -2.185 | [-4.390, 0.418] | 0.667 | [0.429, 1.061] |
| single | Telar GUI | p95 | 6 | -4.129 | [-8.949, 1.208] | 0.486 | [0.265, 0.921] |
| single | Telar TUI + Ghostty | p50 | 6 | +3.276 | [1.142, 6.147] | 1.423 | [1.148, 1.926] |
| single | Telar TUI + Ghostty | p95 | 6 | +5.067 | [2.079, 8.199] | 1.294 | [1.123, 1.495] |

IC mediante 10,000 remuestreos de rondas emparejadas, semilla 20260918. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.

Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. Los splits de Ghostty usan render targets independientes; el tamaño del target del pane principal puede diferir del de la escena completa de Telar.
