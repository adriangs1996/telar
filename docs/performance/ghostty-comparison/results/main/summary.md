# Ghostty y Telar

Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.

Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde a las medianas de las rondas independientes.

| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| single | Ghostty | 6 | 1200 | 6.653 | 11.737 | 14.613 | 19.487 | [6.543, 6.797] |
| single | Telar GUI | 6 | 1200 | 2.361 | 2.714 | 6.410 | 27.117 | [2.293, 2.387] |
| single | Telar TUI + Ghostty | 6 | 1200 | 6.820 | 13.896 | 17.049 | 19.312 | [6.684, 7.682] |
| splits | Ghostty | 4 | 400 | 7.048 | 12.496 | 13.997 | 14.717 | [6.820, 7.260] |
| splits | Telar GUI | 4 | 400 | 2.470 | 3.246 | 16.854 | 23.761 | [2.450, 2.484] |
| splits-load | Ghostty | 4 | 400 | 7.377 | 12.610 | 13.449 | 14.109 | [6.585, 7.582] |
| splits-load | Telar GUI | 4 | 400 | 14.489 | 22.989 | 26.125 | 26.880 | [13.643, 15.743] |
| tabs | Ghostty | 4 | 400 | 6.797 | 12.489 | 16.053 | 17.475 | [6.585, 7.641] |
| tabs | Telar GUI | 4 | 400 | 2.396 | 2.722 | 7.386 | 35.943 | [2.179, 2.502] |
| tabs-load | Ghostty | 4 | 400 | 7.111 | 12.812 | 16.079 | 22.059 | [6.609, 7.637] |
| tabs-load | Telar GUI | 4 | 400 | 1.392 | 4.082 | 7.781 | 37.099 | [1.349, 1.448] |

Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es la media de las diferencias entre percentiles por ronda y el cociente es la media geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.

| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |
| single | Telar GUI | p50 | 6 | -4.301 | [-4.363, -4.257] | 0.354 | [0.350, 0.357] |
| single | Telar GUI | p95 | 6 | -9.159 | [-9.813, -8.663] | 0.230 | [0.218, 0.245] |
| single | Telar TUI + Ghostty | p50 | 6 | +0.436 | [0.187, 0.702] | 1.064 | [1.028, 1.104] |
| single | Telar TUI + Ghostty | p95 | 6 | +1.882 | [1.218, 2.378] | 1.160 | [1.101, 1.204] |
| splits | Telar GUI | p50 | 4 | -4.610 | [-4.752, -4.435] | 0.349 | [0.342, 0.358] |
| splits | Telar GUI | p95 | 4 | -8.210 | [-9.386, -6.999] | 0.319 | [0.237, 0.428] |
| splits-load | Telar GUI | p50 | 4 | +7.032 | [6.455, 7.744] | 1.967 | [1.866, 2.074] |
| splits-load | Telar GUI | p95 | 4 | +10.692 | [9.334, 12.050] | 1.863 | [1.709, 2.030] |
| tabs | Telar GUI | p50 | 4 | -4.645 | [-5.008, -4.307] | 0.338 | [0.324, 0.353] |
| tabs | Telar GUI | p95 | 4 | -9.429 | [-9.788, -9.085] | 0.224 | [0.217, 0.233] |
| tabs-load | Telar GUI | p50 | 4 | -5.726 | [-6.144, -5.307] | 0.196 | [0.181, 0.212] |
| tabs-load | Telar GUI | p95 | 4 | -9.770 | [-11.832, -6.886] | 0.201 | [0.134, 0.375] |

IC mediante 10,000 remuestreos de rondas emparejadas, semilla 20260918. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.

Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. Los splits de Ghostty usan render targets independientes; el tamaño del target del pane principal puede diferir del de la escena completa de Telar.
