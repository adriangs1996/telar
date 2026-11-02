"""Qualify a native display clock and classify intervals between content changes.

The caller must separately validate pixels, producer coverage, focus, display sync,
and native readiness. These functions do not establish complete-flow acceptance
or sustained 120 content FPS. Clock and interval tolerances are fixed constants.
"""
import math
import statistics

INTERVAL_RESIDUAL_SECONDS = .00025
REFERENCE_RELATIVE_TOLERANCE = .05


def classify_gaps(gaps, period):
    if not math.isfinite(period) or period <= 0 or not gaps:
        raise ValueError('missing finite display period or native intervals')
    periods = []
    for gap in gaps:
        if not math.isfinite(gap) or gap <= 0:
            raise ValueError('invalid native interval')
        opportunities = round(gap / period)
        if opportunities < 1 or abs(gap - opportunities * period) > INTERVAL_RESIDUAL_SECONDS:
            raise ValueError('native interval is not aligned with the qualified display period')
        periods.append(opportunities)
    return dict(missed_refresh_opportunities_between_changes=sum(n - 1 for n in periods),
                intervals_in_refresh_periods={str(n): periods.count(n) for n in sorted(set(periods))},
                interval_residual_tolerance_ms=INTERVAL_RESIDUAL_SECONDS * 1000)


def qualify_display(result):
    reference = result['cadence_display_reference']
    if (reference['status'] != 0 or reference['sample_count'] != len(reference['samples'])
            or reference['sample_count'] > reference['capacity'] or not reference['requested_display_id']
            or len({reference[k] for k in ('requested_display_id', 'actual_display_id', 'window_display_id')}) != 1
            or reference['window_display_id'] != result['display_id']):
        raise ValueError('invalid, incomplete or mismatched native display reference')
    if any(not math.isfinite(reference[key]) or reference[key] <= 0
           for key in ('timebase_numer', 'timebase_denom')):
        raise ValueError('invalid native timebase')
    seconds_per_tick = reference['timebase_numer'] / reference['timebase_denom'] / 1e9
    flags = [reference[key] for key in ('host_time_flag', 'video_time_flag', 'video_period_flag')]
    if len(set(flags)) != len(flags) or any(flag <= 0 or flag & (flag - 1) for flag in flags):
        raise ValueError('invalid native clock flag definitions')
    required_flags = flags[0] | flags[1] | flags[2]
    samples = reference['samples']
    if len(samples) < 2 or any(s['flags'] & required_flags != required_flags
                               or any(not math.isfinite(s[key]) or s[key] <= 0
                                      for key in ('refresh_period', 'time_scale')) for s in samples):
        raise ValueError('missing valid Core Video host/video/refresh timestamps')
    output = [s['output_ticks'] * seconds_per_tick for s in samples]
    if any(not math.isfinite(t) or t <= 0 for t in output) or any(b <= a for a, b in zip(output, output[1:])):
        raise ValueError('nonmonotonic display-reference clock')
    start, end = result['cadence']['window_start'], result['cadence']['window_end']
    if not math.isfinite(start) or not math.isfinite(end) or start <= 0 or end <= start:
        raise ValueError('invalid native observation window')
    if output[0] > start or output[-1] < end:
        raise ValueError('display reference does not cover native observation window')
    selected = [(t, s) for t, s in zip(output, samples) if start <= t < end]
    if len(selected) < 2:
        raise ValueError('too few display-reference observations')
    periods = [s['refresh_period'] / s['time_scale'] for _, s in selected]
    period = statistics.median(periods)
    if not math.isfinite(period) or period <= 0:
        raise ValueError('invalid display-reference period')
    host_gaps = [b[0] - a[0] for a, b in zip(selected, selected[1:])]
    if (any(abs(v / period - 1) > REFERENCE_RELATIVE_TOLERANCE for v in periods)
            or any(abs(gap / period - 1) > REFERENCE_RELATIVE_TOLERANCE for gap in host_gaps)):
        raise ValueError('display reference changed cadence/phase or missed callback coverage')
    native = sorted(result['cadence']['frames'], key=lambda f: f['presented_at'])
    changed = [f for i, f in enumerate(native) if i == 0 or f['sequence'] != native[i - 1]['sequence']]
    gaps = [b['presented_at'] - a['presented_at'] for a, b in zip(changed, changed[1:])]
    result = dict(display_reference_qualified=True, display_id=reference['window_display_id'],
                reference_refresh_hz=1 / period, reference_samples_in_window=len(selected),
                reference_host_interval_p50_ms=statistics.median(host_gaps) * 1000,
                reference_host_interval_min_ms=min(host_gaps) * 1000,
                reference_host_interval_max_ms=max(host_gaps) * 1000,
                reference_relative_tolerance=REFERENCE_RELATIVE_TOLERANCE,
                changed_per_observation_second=len(changed) / (end - start))
    try:
        result.update(classify_gaps(gaps, period), active_refresh_qualified=True,
                      missed_refresh_classification_qualified=True)
    except ValueError as error:
        result.update(active_refresh_qualified=False, missed_refresh_classification_qualified=False,
                      interval_classification_error=str(error),
                      interval_residual_tolerance_ms=INTERVAL_RESIDUAL_SECONDS * 1000)
    return result
