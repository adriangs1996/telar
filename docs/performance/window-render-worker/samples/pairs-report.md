### Four panes, three flooding (`gui_tui_latency.py --mode gui --cases single splits-load --panes 4`)

| Case | Metric | A median ms | B median ms | paired change | B wins | A range | B range |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| single | p50 | 2.17 | 2.07 | +6.4% | 2/7 | 1.70..2.27 | 1.72..2.54 |
| single | p95 | 5.21 | 5.37 | -7.3% | 5/7 | 4.86..6.45 | 4.36..5.60 |
| single | p99 | 6.97 | 6.31 | -25.7% | 5/7 | 5.42..10.12 | 4.70..11.47 |
| splits-load | p50 | 6.00 | 6.02 | -1.1% | 4/7 | 5.85..6.09 | 5.50..6.12 |
| splits-load | p95 | 9.78 | 9.80 | +0.3% | 2/7 | 9.72..9.84 | 9.72..9.95 |
| splits-load | p99 | 10.10 | 9.99 | -0.2% | 4/7 | 9.76..10.47 | 9.78..11.44 |

Viewports: [1900, 1100]. GUI process usage over each run (ps):

| Build | peak RSS MiB (median of runs) | CPU time s (median of runs) |
| --- | ---: | ---: |
| A | 163 | 1.94 |
| B | 142 | 1.90 |

### One pane (`gui_latency.py`, graphics gate configuration)

| Case | Metric | A median ms | B median ms | paired change | B wins | A range | B range |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| dense | p50 | 2.56 | 2.66 | +2.5% | 3/7 | 2.54..2.69 | 1.99..2.91 |
| dense | p95 | 5.76 | 6.00 | +5.8% | 2/7 | 4.82..6.70 | 4.66..6.79 |
| dense | p99 | 8.41 | 9.39 | +8.1% | 0/7 | 6.34..10.49 | 8.90..11.32 |
| idle | p50 | 2.29 | 2.34 | -2.6% | 4/7 | 2.00..2.55 | 1.95..2.51 |
| idle | p95 | 5.51 | 5.12 | -4.0% | 5/7 | 4.98..7.43 | 4.57..6.73 |
| idle | p99 | 8.36 | 8.43 | +9.0% | 3/7 | 6.59..10.17 | 5.48..12.61 |
| image120 | p50 | 3.07 | 2.36 | -14.4% | 5/7 | 2.04..8.22 | 2.06..4.15 |
| image120 | p95 | 9.36 | 9.44 | -2.6% | 4/7 | 7.35..17.79 | 8.31..19.87 |
| image120 | p99 | 11.36 | 11.54 | -11.2% | 4/7 | 9.05..22.63 | 9.70..23.95 |
| text120 | p50 | 6.06 | 6.05 | +1.2% | 3/7 | 3.21..8.84 | 1.85..9.60 |
| text120 | p95 | 16.53 | 10.97 | -10.4% | 6/7 | 8.72..22.23 | 9.33..18.62 |
| text120 | p99 | 17.36 | 17.80 | -5.2% | 5/7 | 11.23..25.55 | 10.86..26.08 |

Viewports seen: (3560, 2100, 2.0).

| Build | peak RSS MiB (median of runs) | CPU time s (median of runs) |
| --- | ---: | ---: |
| A | 121 | 0.78 |
| B | 121 | 0.83 |

verdicts: {'single/p50_ms': '2/7', 'single/p95_ms': '5/7', 'single/p99_ms': '5/7', 'splits-load/p50_ms': '4/7', 'splits-load/p95_ms': '2/7', 'splits-load/p99_ms': '4/7', 'dense/p50_ms': '3/7', 'dense/p95_ms': '2/7', 'dense/p99_ms': '0/7', 'idle/p50_ms': '4/7', 'idle/p95_ms': '5/7', 'idle/p99_ms': '3/7', 'image120/p50_ms': '5/7', 'image120/p95_ms': '4/7', 'image120/p99_ms': '4/7', 'text120/p50_ms': '3/7', 'text120/p95_ms': '6/7', 'text120/p99_ms': '5/7'}
