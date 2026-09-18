"""Render the controlled benchmark summary with matplotlib.

Usage: uv run --with matplotlib docs/performance/ghostty-comparison/figures/render.py
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


ROOT = Path(__file__).resolve().parent.parent


def read_summary(name):
    return json.loads((ROOT / 'results' / name / 'summary.json').read_text())['cases']


main = read_summary('main')
control = read_summary('vsync-off')
native_rates = read_summary('throughput-native')['single']['modes']
tui_rates = read_summary('throughput-tui')['single']['modes']
colors = {'ghostty': '#2369ad', 'gui': '#d15a21', 'tui': '#15826c'}
labels = {'ghostty': 'Ghostty', 'gui': 'Telar GUI', 'tui': 'Telar TUI'}

plt.rcParams.update({'font.size': 10, 'axes.spines.top': False,
                     'axes.spines.right': False, 'axes.titleweight': 'bold'})
figure, axes = plt.subplots(1, 2, figsize=(13.5, 5.4), gridspec_kw={'width_ratios': [1.3, 1]})
rows = [('Un panel · Ghostty VSync activado', main['single']),
        ('Un panel · Ghostty VSync desactivado', control['single']),
        ('4 splits · 3 productores saturando', main['splits-load']),
        ('4 pestañas · 3 productores ocultos', main['tabs-load'])]

for index, (_, case) in enumerate(rows):
    for mode, offset in [('ghostty', -.14), ('gui', .14)]:
        values = case['modes'][mode]['pooled']
        y = index + offset
        axes[0].plot([values['p50_ms'], values['p95_ms']], [y, y],
                     color=colors[mode], alpha=.4, linewidth=2)
        axes[0].scatter(values['p50_ms'], y, color=colors[mode], s=44, marker='o', zorder=3)
        axes[0].scatter(values['p95_ms'], y, color=colors[mode], s=42, marker='x', zorder=3)

axes[0].set_yticks(range(len(rows)), [label for label, _ in rows])
axes[0].invert_yaxis()
axes[0].set_xlim(0, 27)
axes[0].set_ylim(3.6, -.65)
axes[0].set_xlabel('Milisegundos · menor es mejor')
axes[0].set_title('Entrada → callback de GPU', loc='left', pad=18)
axes[0].grid(axis='x', alpha=.2)
axes[0].legend(handles=[Line2D([], [], color=colors[mode], label=labels[mode])
                        for mode in ('ghostty', 'gui')] +
                       [Line2D([], [], color='#333333', marker=marker, linestyle='', label=label)
                        for marker, label in [('o', 'p50'), ('x', 'p95')]],
               loc='lower right', frameon=False, ncol=2)

for index, workload in enumerate(('ascii', 'ansi')):
    for mode, offset in [('ghostty', -.23), ('gui', 0), ('tui', .23)]:
        source = tui_rates if mode == 'tui' else native_rates
        stats = source[mode]['throughput'][workload]
        median = stats['median_mib_per_second']
        low, high = stats['range_mib_per_second']
        axes[1].barh(index + offset, median, height=.18, color=colors[mode],
                     label=labels[mode] if index == 0 else None)
        axes[1].errorbar(median, index + offset, xerr=[[median - low], [high - median]],
                         color='#333333', capsize=3, linewidth=1)
        axes[1].text(high + 2, index + offset, f'{median:.2f}', va='center', fontsize=9)

axes[1].set_yticks([0, 1], ['ASCII', 'ANSI'])
axes[1].set_xlim(0, 105)
axes[1].set_ylim(1.6, -.6)
axes[1].set_xlabel('MiB/s · mayor es mejor')
axes[1].set_title('Caudal de PTY → respuesta DSR', loc='left', pad=18)
axes[1].grid(axis='x', alpha=.2)
axes[1].set_axisbelow(True)
axes[1].legend(loc='lower right', frameon=False)

figure.suptitle('Ghostty 1.3.1 y Telar · Apple M3 · 18 septiembre 2026', x=.04,
               ha='left', fontsize=15, weight='bold')
figure.text(.04, .05, 'Ventana activa, escena 1000 × 700. El control de VSync cambia solo Ghostty. '
                     'El callback GPU no mide presentación física.', fontsize=9, color='#444444')
figure.text(.04, .015, 'Caudal: mediana y rango de seis ejecuciones de 8 MiB por carga. '
                      'La TUI se midió en una serie posterior. Las barras de rango no son intervalos de confianza.',
            fontsize=9, color='#444444')
figure.tight_layout(rect=(0, .11, 1, .9), w_pad=3)
for extension in ('svg', 'png'):
    figure.savefig(ROOT / 'figures' / f'comparison.{extension}', dpi=180,
                   facecolor='white', metadata={'Creator': 'Telar benchmark tools'} if extension == 'svg' else None)
