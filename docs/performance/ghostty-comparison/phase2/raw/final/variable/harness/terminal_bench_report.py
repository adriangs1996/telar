#!/usr/bin/env python3
"""Summarize terminal comparison runs and bootstrap paired round differences.

Usage: python3 tools/terminal_bench_report.py comparison.json --output report
Each bootstrap draw resamples complete paired rounds, keeping the dependence
among observations from a single run. Pooled quantiles are descriptive only.
"""

import argparse
import json
import math
from pathlib import Path
import random
import statistics

from echo_latency import percentile


BOOTSTRAP_SAMPLES = 10000
BOOTSTRAP_SEED = 20260918
MODE_ORDER = ('ghostty', 'gui', 'tui')
MODE_LABELS = {'ghostty': 'Ghostty', 'gui': 'Telar GUI', 'tui': 'Telar TUI + Ghostty'}


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def quantiles(values):
    return dict(n=len(values), p50_ms=statistics.median(values),
                p95_ms=percentile(values, .95), p99_ms=percentile(values, .99),
                max_ms=max(values))


def load_runs(paths):
    runs, seen, sources = [], set(), []
    for path in paths:
        report = json.loads(path.read_text())
        sources.append(dict(path=str(path.resolve()), manifest=report.get('manifest', {})))
        for run in report['runs']:
            case, mode, round_index = run['case'], run['mode'], run['round']
            identity = case, mode, round_index
            if not isinstance(case, str) or mode not in MODE_ORDER:
                raise ValueError(f'invalid case or mode: {identity}')
            if not isinstance(round_index, int) or isinstance(round_index, bool) or round_index < 0:
                raise ValueError(f'invalid round: {identity}')
            if identity in seen:
                raise ValueError(f'duplicate case/mode/round: {identity}')
            seen.add(identity)
            warmup, samples = run['warmup'], run['gpu_ms']
            if (not isinstance(warmup, int) or isinstance(warmup, bool) or
                    not isinstance(samples, list) or not 0 <= warmup < len(samples)):
                raise ValueError(f'invalid warmup or empty samples: {identity}')
            if run.get('failed', 0) or any(not finite_number(value) or value < 0 for value in samples):
                raise ValueError(f'failed or invalid measurement: {identity}')
            values = samples[warmup:]
            runs.append(dict(raw=run, source=str(path.resolve()), values=values,
                             summary=quantiles(values), case=case, mode=mode, round=round_index))
    if not runs:
        raise ValueError('no measurement runs were supplied')
    return runs, sources


def paired_statistics(reference, candidate):
    reference_rounds = {run['round']: run for run in reference}
    candidate_rounds = {run['round']: run for run in candidate}
    paired = sorted(reference_rounds.keys() & candidate_rounds.keys())
    result = dict(rounds=paired, n_rounds=len(paired),
                  unpaired_reference_rounds=sorted(reference_rounds.keys() - candidate_rounds.keys()),
                  unpaired_candidate_rounds=sorted(candidate_rounds.keys() - reference_rounds.keys()),
                  quantiles={})
    if not paired:
        return result
    for name in ('p50_ms', 'p95_ms'):
        baseline = [reference_rounds[index]['summary'][name] for index in paired]
        measured = [candidate_rounds[index]['summary'][name] for index in paired]
        differences = [after - before for before, after in zip(baseline, measured)]
        positive = all(before > 0 and after > 0 for before, after in zip(baseline, measured))
        log_ratios = [math.log(after / before) for before, after in zip(baseline, measured)] if positive else []
        entry = dict(paired_deltas_ms=differences, mean_delta_ms=statistics.mean(differences),
                     median_delta_ms=statistics.median(differences),
                     delta_range_ms=[min(differences), max(differences)],
                     geometric_mean_ratio=math.exp(statistics.mean(log_ratios)) if positive else None,
                     mean_delta_ci95_ms=None, geometric_mean_ratio_ci95=None)
        if len(paired) >= 2:
            generator = random.Random(BOOTSTRAP_SEED)
            bootstrap_differences, bootstrap_ratios = [], []
            for _ in range(BOOTSTRAP_SAMPLES):
                indices = [generator.randrange(len(paired)) for _ in paired]
                bootstrap_differences.append(sum(differences[index] for index in indices) / len(indices))
                if positive:
                    bootstrap_ratios.append(math.exp(sum(log_ratios[index] for index in indices) / len(indices)))
            entry['mean_delta_ci95_ms'] = [percentile(bootstrap_differences, .025),
                                          percentile(bootstrap_differences, .975)]
            if positive:
                entry['geometric_mean_ratio_ci95'] = [percentile(bootstrap_ratios, .025),
                                                       percentile(bootstrap_ratios, .975)]
        result['quantiles'][name.removesuffix('_ms')] = entry
    return result


def throughput_statistics(runs):
    workloads = {}
    for run in runs:
        throughput = run['raw'].get('throughput')
        if throughput is None:
            continue
        if throughput.get('failed') or throughput.get('endpoint') != 'pty_write_to_dsr_response':
            raise ValueError(f'invalid throughput result in {run["source"]}')
        for sample in throughput['cases']:
            name, rate = sample['name'], sample['mib_per_second']
            if not isinstance(name, str) or not finite_number(rate) or rate <= 0:
                raise ValueError(f'invalid throughput sample: {sample}')
            workloads.setdefault(name, []).append(dict(round=run['round'], mib_per_second=rate,
                                                       bytes=sample['bytes'], elapsed_ms=sample['elapsed_ms']))
    return {name: dict(n=len(samples), median_mib_per_second=statistics.median(
                      [sample['mib_per_second'] for sample in samples]),
                      range_mib_per_second=[min(sample['mib_per_second'] for sample in samples),
                                            max(sample['mib_per_second'] for sample in samples)],
                      samples=samples)
            for name, samples in sorted(workloads.items())}


def summarize_runs(runs, sources):
    result = dict(endpoint='native_input_to_verified_gpu_completion_callback',
                  bootstrap=dict(samples=BOOTSTRAP_SAMPLES, seed=BOOTSTRAP_SEED,
                                 resampling_unit='paired_round', confidence=.95,
                                 interval='percentile', delta_estimator='mean_of_paired_run_quantile_differences',
                                 ratio_estimator='geometric_mean_of_paired_run_quantile_ratios'),
                  sources=sources, cases={})
    for case in sorted({run['case'] for run in runs}):
        selected = [run for run in runs if run['case'] == case]
        input_methods = {run['raw'].get('input_method', 'key') for run in selected}
        if len(input_methods) > 1:
            raise ValueError(f'mixed native input endpoints in case {case}: {input_methods}')
        variants, case_result = {}, dict(input_method=next(iter(input_methods)), modes={}, paired={})
        for mode in MODE_ORDER:
            measurements = sorted([run for run in selected if run['mode'] == mode], key=lambda run: run['round'])
            if not measurements:
                continue
            variants[mode] = measurements
            values = [value for run in measurements for value in run['values']]
            medians = [run['summary']['p50_ms'] for run in measurements]
            geometry = [dict(round=run['round'], **{name: run['raw'][name]
                        for name in ('viewport', 'requested_viewport', 'window_content_pixels',
                                     'primary_view_pixels', 'native_view_pixels', 'pty_cells')
                        if name in run['raw']}) for run in measurements]
            case_result['modes'][mode] = dict(pooled=quantiles(values), n_rounds=len(measurements),
                                            run_p50_range_ms=[min(medians), max(medians)], geometry=geometry,
                                            runs=[dict(round=run['round'], **run['summary']) for run in measurements],
                                            throughput=throughput_statistics(measurements))
        if 'ghostty' in variants:
            for mode in ('gui', 'tui'):
                if mode in variants:
                    case_result['paired'][mode] = paired_statistics(variants['ghostty'], variants[mode])
        result['cases'][case] = case_result
    return result


def interval_text(values, digits=3):
    if values is None:
        return 'Sin IC'
    return f'[{values[0]:.{digits}f}, {values[1]:.{digits}f}]'


def markdown_report(report):
    lines = ['# Ghostty y Telar', '',
             'Latencia desde la inyección de entrada nativa hasta el callback que confirma una operación de GPU '
             'con el píxel esperado. No mide presentación física ni permite atribuir las diferencias al socket Unix.', '',
             'Cada fila agrupa las muestras posteriores al calentamiento. El rango de p50 corresponde '
             'a las medianas de las rondas independientes.', '',
             '| Caso | Aplicación | Rondas | Muestras | p50 ms | p95 ms | p99 ms | Máximo ms | Rango p50 por ronda ms |',
             '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |']
    for case, case_result in report['cases'].items():
        for mode, variant in case_result['modes'].items():
            stats = variant['pooled']
            lines.append(f'| {case} | {MODE_LABELS[mode]} | {variant["n_rounds"]} | {stats["n"]} | '
                         f'{stats["p50_ms"]:.3f} | {stats["p95_ms"]:.3f} | {stats["p99_ms"]:.3f} | '
                         f'{stats["max_ms"]:.3f} | {interval_text(variant["run_p50_range_ms"])} |')
    lines.extend(['', 'Las diferencias siguientes emparejan las mismas rondas. Un delta positivo indica '
                  'mayor latencia de Telar; un cociente mayor que 1 tiene el mismo sentido. El delta es '
                  'la media de las diferencias entre percentiles por ronda y el cociente es la media '
                  'geométrica de sus cocientes. No son diferencias entre los percentiles agrupados de la tabla anterior.', '',
                  '| Caso | Comparación con Ghostty | Percentil | Rondas emparejadas | Delta medio ms | IC 95% delta ms | Cociente | IC 95% cociente |',
                  '| --- | --- | --- | ---: | ---: | --- | ---: | --- |'])
    warnings = []
    for case, case_result in report['cases'].items():
        for mode, paired in case_result['paired'].items():
            if paired['unpaired_reference_rounds'] or paired['unpaired_candidate_rounds']:
                warnings.append(f'{case}/{mode}: se excluyen del emparejamiento las rondas sin pareja. '
                                'Sus índices constan en summary.json.')
            if not paired['n_rounds']:
                warnings.append(f'{case}/{mode}: no hay rondas comunes para una comparación emparejada.')
            for quantile, stats in paired['quantiles'].items():
                ratio = stats['geometric_mean_ratio']
                ratio_text = f'{ratio:.3f}' if ratio is not None else 'No calculable'
                lines.append(f'| {case} | {MODE_LABELS[mode]} | {quantile} | {paired["n_rounds"]} | '
                             f'{stats["mean_delta_ms"]:+.3f} | {interval_text(stats["mean_delta_ci95_ms"])} | '
                             f'{ratio_text} | {interval_text(stats["geometric_mean_ratio_ci95"])} |')
    lines.extend(['', f'IC mediante {BOOTSTRAP_SAMPLES:,} remuestreos de rondas emparejadas, semilla '
                  f'{BOOTSTRAP_SEED}. Una sola ronda no produce IC. Pocas rondas y pocos valores en la cola '
                  'limitan la precisión, especialmente en p99. Un IC del delta que incluya cero no permite '
                  'afirmar una dirección con este procedimiento. Los intervalos describen estas ejecuciones.', ''])
    if warnings:
        lines.extend(['- ' + warning for warning in warnings] + [''])
    throughput_rows = []
    for case, case_result in report['cases'].items():
        for mode, variant in case_result['modes'].items():
            for workload, stats in variant['throughput'].items():
                throughput_rows.append(f'| {case} | {MODE_LABELS[mode]} | {workload} | {stats["n"]} | '
                                       f'{stats["median_mib_per_second"]:.2f} | '
                                       f'{interval_text(stats["range_mib_per_second"], 2)} |')
    if throughput_rows:
        lines.extend(['El caudal termina al recibir la respuesta DSR del emulador después de procesar '
                      'los bytes escritos en la PTY. Esa frontera precede a la finalización de GPU y '
                      'no mide cuántos fotogramas se presentan.', '',
                      '| Caso | Aplicación | Carga | Ejecuciones | Mediana MiB/s | Rango MiB/s |',
                      '| --- | --- | --- | ---: | ---: | --- |', *throughput_rows, ''])
    lines.extend(['Las geometrías de ventana, render target y PTY declaradas por cada ejecución, las '
                  'muestras de caudal, los deltas por ronda y los manifiestos originales quedan en summary.json. '
                  'Los splits de Ghostty usan render targets independientes; el tamaño del target del pane '
                  'principal puede diferir del de la escena completa de Telar.', ''])
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    runs, sources = load_runs(args.inputs)
    report = summarize_runs(runs, sources)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    (args.output / 'summary.md').write_text(markdown_report(report))
    print(args.output / 'summary.md')


if __name__ == '__main__':
    main()
