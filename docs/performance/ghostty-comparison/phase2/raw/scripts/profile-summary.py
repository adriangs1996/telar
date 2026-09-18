#!/usr/bin/env python3
"""Summarize macOS sample call trees without recursive inclusive double counting."""
import argparse
import collections
import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Node:
    samples: int
    symbol: str
    location: str
    line: int
    depth: int
    children: list = field(default_factory=list)

    @property
    def self_samples(self):
        value = self.samples - sum(child.samples for child in self.children)
        assert value >= 0, (self.line, self.symbol, value)
        return value


def parse(path):
    raw = path.read_bytes()
    lines = raw.decode().splitlines()
    roots, stack = [], []
    active = False
    for number, line in enumerate(lines, 1):
        if line == 'Call graph:':
            active = True
            continue
        if not active:
            continue
        if line.startswith('Total number in stack'):
            break
        if not line.strip():
            continue
        match = re.match(r'^([ +!:|]*)(\d+) (.*)$', line)
        if not match:
            raise ValueError(f'Unknown call graph line {number}: {line}')
        prefix, count, description = match.groups()
        symbol, separator, location = description.partition('  (in ')
        node = Node(int(count), symbol, '(in ' + location if separator else '', number, len(prefix))
        while stack and stack[-1].depth >= node.depth:
            stack.pop()
        if stack:
            stack[-1].children.append(node)
        else:
            roots.append(node)
        stack.append(node)
    for root in roots:
        assert sum(node.self_samples for node in walk(root)) == root.samples
    return raw, lines, roots


def walk(root):
    yield root
    for child in root.children:
        yield from walk(child)


def matched_nodes(root, predicate):
    if predicate(root.symbol):
        yield root
    else:
        for child in root.children:
            yield from matched_nodes(child, predicate)


def metric(roots, predicate, denominator=None):
    nodes = [node for root in roots for node in matched_nodes(root, predicate)]
    by_site = {}
    for node in nodes:
        key = (node.symbol, node.location)
        entry = by_site.setdefault(key, {'function': node.symbol, 'location': node.location, 'samples': 0, 'profile_lines': []})
        entry['samples'] += node.samples
        entry['profile_lines'].append(node.line)
    result = {'inclusive_samples': sum(node.samples for node in nodes), 'callsites': sorted(by_site.values(), key=lambda item: -item['samples'])}
    if denominator is not None:
        result['denominator_main_thread_samples'] = denominator
        result['percentage_of_main_thread_samples'] = 100 * result['inclusive_samples'] / denominator
    return result


MAIN = {
    'event_queue_get': lambda name: name == 'Io.TypeErasedQueue.getLocked',
    'futex_wait': lambda name: name == '__ulock_wait2',
    'client_pump': lambda name: name == 'runtime.application.Application.pump',
    'cell_prepare': lambda name: name == 'runtime.attachment.CellSync.prepare',
    'pane_render': lambda name: name == 'pane.Pane.render',
    'blit': lambda name: name == 'pane.blit.blit',
    'style_comparison': lambda name: name == 'ui.Style.eql',
    'foreground_group_probe': lambda name: name in ('tcgetpgrp', 'DYLD-STUB$$tcgetpgrp'),
    'task_scheduling': lambda name: name == 'Io.Threaded.groupConcurrent',
    'deadline_schedule': lambda name: name == 'runtime.application.Application.scheduleCellPublication',
    'clock_read': lambda name: name == 'Io.Threaded.now',
}
WORKER = {
    'observation': lambda name: 'GenericProjectionDispatcher' in name and name.endswith('.observePane'),
    'observation_screen_signal': lambda name: name == 'history.Sample.signal',
    'observation_sample_capture': lambda name: name == 'history.Sample.capture',
    'media_processing': lambda name: name == 'media.Processor.processMedia',
    'media_ingest': lambda name: name == 'media.Processor.ingestMediaOutput',
    'canonical_ingest': lambda name: 'GenericPipelineDispatcher' in name and name.endswith('.ingestPane'),
    'queue_completion_put': lambda name: name in ('Io.TypeErasedQueue.putUncancelable', 'Io.TypeErasedQueue.putLocked'),
    'socket_read_operation': lambda name: name == 'Io.Threaded.netReadPosix',
    'socket_write_operation': lambda name: name == 'Io.Threaded.netWritePosix',
    'poll_syscall': lambda name: name == 'poll',
    'foreground_group_probe': MAIN['foreground_group_probe'],
    'futex_wait': MAIN['futex_wait'],
    'futex_wake': lambda name: name == '__ulock_wake',
    'deadline_timer_wait': lambda name: name in ('time.deadline_timer.wait', 'deadline_timer.wait'),
    'signal_trampoline': lambda name: name == '_sigtramp',
}


def top_self(roots, limit=30):
    totals = collections.Counter()
    lines = collections.defaultdict(list)
    for root in roots:
        for node in walk(root):
            if node.self_samples:
                totals[node.symbol] += node.self_samples
                lines[node.symbol].append(node.line)
    return [{'function': name, 'self_samples': samples, 'profile_lines': lines[name]} for name, samples in totals.most_common(limit)]


def summarize(path):
    raw, lines, roots = parse(path)
    main = next(root for root in roots if 'com.apple.main-thread' in root.symbol)
    workers = [root for root in roots if root is not main]
    timestamp = next(line.partition(':')[2].strip() for line in lines if line.startswith('Date/Time:'))
    report = {
        'schema_version': 1,
        'source': {'path': str(path), 'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'profile_date_time': timestamp},
        'method': {
            'aggregation': 'Parse call graph indentation. Sum inclusive matches unless an ancestor already matches that metric. Assert every self count nonnegative and per-thread self sum equals root count. Profile lines are 1-based.',
            'scope': 'Main denominator includes waiting and runnable samples; percentages are not CPU shares. Worker totals span different pooled threads and are not comparable to main percentages. Nested metrics overlap and must not be added.',
        },
        'main_thread': {'name': main.symbol, 'samples': main.samples, 'metrics': {key: metric([main], predicate, main.samples) for key, predicate in MAIN.items()}, 'top_self': top_self([main])},
        'workers': {'threads': [{'name': root.symbol, 'samples': root.samples} for root in workers], 'total_thread_samples': sum(root.samples for root in workers), 'metrics': {key: metric(workers, predicate) for key, predicate in WORKER.items()}, 'top_self': top_self(workers)},
        'limits': [
            'Wall-stack sampling includes sleeping threads, kernel calls and scheduler delay; these are not CPU percentages.',
            'Nested cell preparation/render/blit and observation/screen-signal counts overlap.',
            'poll(timeout=0) does not wait for future readiness, but samples can include syscall work or descheduling.',
            'Socket readv presence is not evidence that IPC is the critical path.',
            'An 8 s profile may cross workload phases; consult result timings before labelling its scope.',
            'One profile is evidence for hypotheses, not proof of causal speedup or a quantified performance ceiling.',
        ],
    }
    for name in ('result', 'shutdown'):
        sibling = path.with_name(name + '.json')
        if sibling.exists():
            report[name] = json.loads(sibling.read_text())
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('sample', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--validate', type=Path)
    args = parser.parse_args()
    report = summarize(args.sample)
    if args.validate:
        reference = json.loads(args.validate.read_text())
        for section in ('main_thread', 'workers'):
            for name, expected in reference[section]['metrics'].items():
                actual = report[section]['metrics'][name]['inclusive_samples']
                assert actual == expected['inclusive_samples'], (section, name, actual, expected['inclusive_samples'])
        assert report['main_thread']['samples'] == reference['main_thread']['samples']
        assert report['workers']['total_thread_samples'] == reference['workers']['total_thread_samples']
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({section: {key: value['inclusive_samples'] for key, value in report[section]['metrics'].items()} for section in ('main_thread', 'workers')}, indent=2))


if __name__ == '__main__':
    main()
