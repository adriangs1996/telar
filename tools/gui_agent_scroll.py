#!/usr/bin/env python3
"""Exercise scroll continuity, wheel motion and folded history in a real macOS window."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_messages import FAKE_CODEX
from gui_agent_lifecycle import wait_for
from gui_multiplexer import Actions, exercise


PROMPT = 'Find the previous visible message without scrolling through hidden tool output.'
ANSWER = 'The work is complete. This response must stay visible while hidden history loads.'
HISTORY = r'''
entries = [{'id': 'prompt', 'type': 'userMessage', 'content': [
    {'type': 'text', 'text': (root / 'prompt.txt').read_text()}]}]
for number in range(24):
    entries.append({'id': 'command-' + str(number), 'type': 'commandExecution',
        'command': 'check-part ' + str(number), 'cwd': '/project/telar',
        'status': 'completed', 'commandActions': [], 'exitCode': 0,
        'aggregatedOutput': ('Completed hidden activity %02d.\n' % number) * 400})
entries.append({'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer',
    'text': (root / 'answer.txt').read_text()})
turn_ids = {entry['id']: 'turn-native' for entry in entries}

def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    for entry in entries[1:]:
        item('completed', entry)
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

'''
CONTINUOUS_HISTORY = r'''
entries = []
turn_ids = {}
for number in range(24):
    prefix = 'turn-' + str(number)
    group = [{'id': prefix + '-prompt', 'type': 'userMessage', 'content': [
        {'type': 'text', 'text': 'Review conversation section ' + str(number)}]}]
    for command in range(4):
        group.append({'id': prefix + '-command-' + str(command), 'type': 'commandExecution',
            'command': 'check-section ' + str(number), 'cwd': '/project/telar',
            'status': 'completed', 'commandActions': [], 'exitCode': 0,
            'aggregatedOutput': ('Completed hidden activity in section %02d.\n' % number) * 400})
    group.append({'id': prefix + '-answer', 'type': 'agentMessage', 'phase': 'final_answer',
        'text': '## Response %d\n\n' % number +
            '\n'.join('Visible result line %d for section %d.' % (line, number) for line in range(7)) +
            '\n\n[Anchor%d](https://example.test/section/%d)\n\nEnd of this response.' % (number, number)})
    entries.extend(group)
    turn_ids.update({entry['id']: 'turn-native' if number == 23 else prefix for entry in group})

def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    for entry in entries[-6:]:
        item('completed', entry)
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

'''
METHODS = r'''
    elif method == 'thread/read':
        emit({'id': message['id'], 'result': {'thread': {
            'id': 'thread-native', 'historyMode': 'paginated'}}})
    elif method == 'thread/items/list':
        params = message['params']
        older = params['sortDirection'] == 'desc'
        cursor = params.get('cursor')
        number = int(cursor.split('-')[1]) if cursor else (len(entries) - 1 if older else 0)
        following = number - 1 if older else number + 1
        if number == 0:
            (root / 'prompt-reached').touch()
            if (root / 'reload-enabled').exists():
                (root / 'prompt-recovered').touch()
        if (root / 'reload-enabled').exists():
            (root / 'reload-read').touch()
        emit({'id': message['id'], 'result': {
            'data': [{'turnId': turn_ids[entries[number]['id']], 'item': entries[number]}],
            'nextCursor': 'position-' + str(following) if 0 <= following < len(entries) else None,
            'backwardsCursor': 'position-' + str(number)}})
'''


def continuous_actions(actions):
    actions.items.extend([{}] * 24)
    actions.capture('continuous-start')
    actions.items.append(dict(record=str(actions.directory / 'position-0.json')))
    deltas = [0.25] * 6 + [-0.125] * 2 + [128] * 70 + [-128] * 70
    for index, delta in enumerate(deltas, 1):
        actions.items.append(dict(scroll=delta, control='Conversation', phase='begin' if index == 1 else 'update'))
        actions.items.append(dict(record=str(actions.directory / f'position-{index}.json')))
        if index in (8, 78):
            actions.capture(f'continuous-{index}')
    actions.capture('continuous-return')
    return deltas


def smooth_actions(actions):
    actions.items.extend([{}] * 24)
    actions.capture('smooth-start')
    trace = str(actions.directory / 'smooth-trace.json')
    actions.items.append(dict(trace_scroll=trace))
    actions.items.append(dict(scroll=3, discrete=True, control='Conversation'))
    actions.items.append(dict(wait=trace))
    actions.capture('smooth-end')


def verify_smooth(directory):
    samples = json.loads((directory / 'smooth-trace.json').read_text())['samples']
    assert len(samples) >= 20, f'Not enough native samples: {len(samples)}'
    assert all(sample['app_active'] and sample['window_key'] for sample in samples), 'Native window lost focus'
    anchors = [{control['label']: control['bounds'] for control in sample['anchors']} for sample in samples]
    shared = set.intersection(*(set(record) for record in anchors))
    shared = [key for key in shared if max(record[key][3] for record in anchors) - min(record[key][3] for record in anchors) < .01]
    assert shared, 'No unclipped anchor remained visible throughout the wheel motion'
    # --no-config uses 15pt text; each wheel line is 24 logical pixels.
    expected_distance = 3 * 24
    results = []
    for key in shared:
        positions = [record[key][1] for record in anchors]
        distances = [positions[0] - position for position in positions]
        assert abs(distances[-1] - expected_distance) < .05, f'Wrong final wheel distance: {key}, {distances[-1]}'
        steps = [following - previous for previous, following in zip(distances, distances[1:])]
        assert min(steps) >= -.02, f'Wheel motion reversed unexpectedly: {key}, {min(steps)}'
        intermediates = {round(distance, 2) for distance in distances if .05 < distance < expected_distance - .05}
        assert len(intermediates) >= 6, f'Wheel motion did not produce intermediate positions: {key}, {len(intermediates)}'
        assert max(steps) < expected_distance * .8, f'Wheel motion jumped: {key}, {max(steps)}'
        settled = [distance for sample, distance in zip(samples, distances) if sample['time_ms'] >= samples[-1]['time_ms'] - 200]
        assert max(settled) - min(settled) < .02, f'Wheel motion failed to settle: {key}, {settled}'
        results.append(dict(anchor=key, intermediate_positions=len(intermediates), final_distance_points=distances[-1],
                            largest_step_points=max(steps), settled_range_points=max(settled) - min(settled)))
    return dict(native_scroll_samples=len(samples), smooth_wheel=True, anchors=results)


def verify_positions(directory, deltas):
    records = [json.loads((directory / f'position-{index}.json').read_text()) for index in range(len(deltas) + 1)]
    anchors = [{control['label']: control['bounds'] for control in record['controls']
                if control['label'].startswith('Anchor')} for record in records]
    assert len(anchors[0]) >= 2, f'Initial viewport was not filled: {anchors[0]}'
    largest_error = 0
    for index, delta in enumerate(deltas):
        shared = anchors[index].keys() & anchors[index + 1].keys()
        shared = [key for key in shared if abs(anchors[index][key][3] - anchors[index + 1][key][3]) < .01]
        assert shared, f'No shared visible anchor at movement {index + 1}'
        for key in shared:
            error = abs(anchors[index + 1][key][1] - anchors[index][key][1] + delta)
            largest_error = max(largest_error, error)
            assert error < .02, f'Anchor jumped at movement {index + 1}: {key}, delta={delta}, error={error}'
    return dict(native_scroll_samples=len(deltas), max_position_error_points=largest_error,
                initial_visible_responses=len(anchors[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--continuous', action='store_true', help='check subpixel movement across multiple collapsed turns')
    mode.add_argument('--smooth', action='store_true', help='trace intermediate native frames after one wheel impulse')
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'prompt.txt').write_text(PROMPT)
    (directory / 'answer.txt').write_text(ANSWER)
    history = CONTINUOUS_HISTORY if args.continuous or args.smooth else HISTORY
    source = FAKE_CODEX[:FAKE_CODEX.index('def turn():')] + history + FAKE_CODEX[FAKE_CODEX.index('for line in sys.stdin:'):]
    source = source.replace("    elif method == 'turn/start':", METHODS + "    elif method == 'turn/start':")
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + source)
    fake.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    runtime_log = (directory / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(binary), 'server', '--no-config'], env=env, cwd=directory,
                               stdout=runtime_log, stderr=runtime_log)
    try:
        wait_for(directory / 'runtime.sock')
        actions = Actions(directory)
        actions.items.append(dict(resize=[1100, 800], activate=True))
        actions.items.extend([{}] * 8)
        actions.prefix('a', 0)
        actions.capture('startup')
        actions.items.append(dict(record=str(directory / 'startup.json')))
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        actions.items.extend([{}] * 3)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text(PROMPT)
        actions.key('\r', 36)
        actions.items.append(dict(wait=str(directory / 'complete-ready')))
        actions.items.extend([{}] * 8)
        if args.continuous:
            deltas = continuous_actions(actions)
        elif args.smooth:
            smooth_actions(actions)
        else:
            actions.capture('before-scroll')
            actions.key('\uf72c', 116)
            actions.items.append(dict(wait=str(directory / 'prompt-reached'), wait_seconds=30))
            actions.items.extend([{}] * 8)
            actions.capture('after-one-scroll')
            actions.items.append(dict(click_label='Copy response'))
            actions.items.extend([{}] * 3)
            actions.items.append(dict(expect_clipboard=ANSWER))
            actions.items.append(dict(signal=str(directory / 'reload-enabled')))
            actions.items.append(dict(click_label='Show agent work'))
            actions.items.append(dict(wait=str(directory / 'reload-read')))
            actions.items.extend([{}] * 8)
            actions.capture('expanded-work')
            actions.items.append(dict(click_label='Hide agent work'))
            actions.items.append(dict(wait=str(directory / 'prompt-recovered'), wait_seconds=30))
            actions.items.extend([{}] * 8)
            actions.capture('collapsed-again')
        exercise(binary, directory, env, library, actions, 'folded-history')
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        reads = [entry for entry in requests if entry.get('method') == 'thread/items/list']
        if args.continuous:
            result = verify_positions(directory, deltas)
            assert any(entry['params']['sortDirection'] == 'asc' for entry in reads), 'Expected newer history reload after eviction'
        elif args.smooth:
            result = verify_smooth(directory)
        else:
            assert len(reads) > 24, 'Expected multiple bounded pages and reloading after expansion'
            result = dict(one_scroll_reached_prompt=True, expansion_reloaded_work=True)
        result['provider_item_reads'] = len(reads)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
        runtime.wait(timeout=10)
        runtime_log.close()


if __name__ == '__main__':
    main()
