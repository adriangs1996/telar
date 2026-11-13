#!/usr/bin/env python3
"""Isolated-process graphics header validation against accepted C++ and Ghostty."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import sys
from check_control_grapheme_rows import RemoteProbe
from control_query_oracle import GHOSTTY


def cases(split_fields=True):
    values = [b'', b'0', b'1', b'113', b'+113', b'q', b'z', b'd', b'-1', b'-0', b'+0', b'-00',
              b'+-1', b'+-0', b'-+1', b'2147483647', b'+2147483647', b'2147483648', b'-2147483648',
              b'-2147483649', b'4294967295', b'4294967296', b'00000000000', b'000000000000', b'++1',
              b'_1', b'1_', b'1__1']
    for key in range(256):
        for value in values:
            field = bytes([key]) + b'=' + value
            for position, header in enumerate([b'a=q,i=9,s=1,v=1,' + field,
                                               field + b',a=q,i=9,s=1,v=1']):
                query = b'\x1b_G' + header + b';AAAAAA==\x1b\\\x1b[6n'
                yield f'key-{key:02x}-value-{value.hex()}-position-{position}', query, None
                if split_fields and key in b'aiIpsvfqOStozHVX':
                    for split in range(len(query) + 1):
                        yield f'key-{key:02x}-value-{value.hex()}-position-{position}', query, split


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--reference', type=Path, default=GHOSTTY)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--no-splits', action='store_true')
    args = parser.parse_args()
    libraries = [path.resolve() for path in [args.native, args.baseline, args.reference]]
    remotes = []
    checked = baseline_differences = application_differences = previous_application_differences = 0
    improved = regressed = 0
    failures = []
    inputs = {}
    difference_cases = {}
    try:
        for path in libraries:
            remotes.append(RemoteProbe(path))
        for name, query, split in cases(not args.no_splits):
            inputs[name] = hashlib.sha256(query).hexdigest()
            request = ((80, 24, 9, 18), b'', None, query, split)
            for remote in remotes:
                remote.send(request)
            replies = [remote.receive() for remote in remotes]
            checked += 1
            baseline_differences += replies[0] != replies[1]
            application_differences += replies[0] != replies[2]
            previous_application_differences += replies[1] != replies[2]
            improved += replies[0] == replies[2] and replies[1] != replies[2]
            regressed += replies[0] != replies[2] and replies[1] == replies[2]
            if replies[0] != replies[1] or replies[0] != replies[2]:
                if name not in difference_cases:
                    difference_cases[name] = {'count': 0, 'first_split': split, 'input': query.hex(),
                                              'responses': [reply.hex() for reply in replies]}
                difference_cases[name]['count'] += 1
            if (replies[0] != replies[1] or replies[0] != replies[2]) and len(failures) < 40:
                failures.append({'case': name, 'split': split, 'input': query.hex(),
                                 'responses': [reply.hex() for reply in replies]})
    finally:
        for remote in remotes:
            remote.close()
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'command': sys.argv, 'checked': checked,
              'candidate_vs_baseline_differences': baseline_differences,
              'candidate_vs_application_differences': application_differences,
              'baseline_vs_application_differences': previous_application_differences,
              'improved_against_application': improved, 'regressed_against_application': regressed,
              'failures': failures, 'difference_cases': difference_cases,
              'libraries_in_separate_processes': True,
              'libraries': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in libraries},
              'harness_sha256': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in
                                 [Path(__file__), Path(__file__).with_name('check_control_grapheme_rows.py')]},
              'inputs_sha256': inputs,
              'scope': 'All256 field-key bytes, numeric/sign/length boundaries and ignored values, both field orders. Selected fields and signed ignored keys split at every byte. Fresh real terminals per trial; trailing CPR checks recovery; native foreign callbacks must remain zero. No real clipboard or valid file/shared-memory path.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['checked', 'candidate_vs_baseline_differences',
                                                  'candidate_vs_application_differences',
                                                  'baseline_vs_application_differences']}))
    return bool(application_differences)


if __name__ == '__main__':
    sys.exit(main())
