"""Retain the owned runtime until a producer checkpoint covers the native window."""
import json
from pathlib import Path
import time


def finish_cadence_fixture(directory: Path):
    result_path = directory / 'result.json'
    if not result_path.exists():
        return
    result = json.loads(result_path.read_text())
    cadence = result.get('cadence')
    if not cadence or result.get('failed') or cadence['window_end'] <= cadence['window_start']:
        return
    began = time.monotonic()
    deadline = began + 3
    observations = []
    path = directory / 'cadence-producer.json'
    while True:
        if path.exists():
            producer = json.loads(path.read_text())
            events = producer.get('events', [])
            if events:
                last = events[-1]
                if not observations or observations[-1]['sequence'] != last['sequence']:
                    observations.append(dict(sequence=last['sequence'], accepted_ns=last['accepted_ns']))
                if last['accepted_ns'] / 1e9 >= cadence['window_end']:
                    (directory / 'cadence-completion.json').write_text(json.dumps(dict(
                        status='checkpoint covers native window before runtime shutdown',
                        waited_seconds=time.monotonic() - began, window_end=cadence['window_end'],
                        observations=observations), indent=2) + '\n')
                    return
        if time.monotonic() >= deadline:
            (directory / 'cadence-completion.json').write_text(json.dumps(dict(
                status='failed: no checkpoint covers native window',
                waited_seconds=time.monotonic() - began, window_end=cadence['window_end'],
                observations=observations), indent=2) + '\n')
            raise RuntimeError('Producer checkpoint did not cover the native cadence window before cleanup')
        time.sleep(.05)
