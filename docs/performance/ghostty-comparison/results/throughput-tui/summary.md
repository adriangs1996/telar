# Ghostty y Telar

Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.

Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde a las medianas de las rondas independientes.

| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| single | Telar TUI + Ghostty | 6 | 6 | 7.403 | 9.701 | 10.299 | 10.449 | [6.345, 10.449] |

Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es la media de las diferencias entre percentiles por ronda y el cociente es la media geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.

| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |

IC mediante 10,000 remuestreos de rondas emparejadas, semilla 20260918. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.

El caudal termina al recibir la respuesta DSR del emulador después de procesar los bytes escritos en la PTY. Esa frontera precede a la finalización de GPU y no mide cuántos fotogramas se presentan.

| Caso | Aplicación | Carga | Ejecuciones | Mediana MiB/s | Rango MiB/s |
| --- | --- | --- | ---: | ---: | --- |
| single | Telar TUI + Ghostty | ansi | 6 | 8.12 | [7.78, 8.27] |
| single | Telar TUI + Ghostty | ascii | 6 | 8.00 | [7.56, 8.09] |

Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. Los splits de Ghostty usan render targets independientes; el tamaño del target del pane principal puede diferir del de la escena completa de Telar.
