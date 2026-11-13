import argparse
import json
from pathlib import Path
import shlex


def write_header_database(build, entries, headers, reference_source, context_name):
    reference = next((entry for entry in entries if (Path(entry['directory']) / entry['file']).resolve() == reference_source), None)
    if reference is None:
        return
    arguments = reference.get('arguments') or shlex.split(reference['command'])
    database = []
    for header in headers:
        database.append(dict(
            directory=reference['directory'],
            file=str(header),
            arguments=[str(header) if argument == reference['file'] else argument for argument in arguments],
        ))
    output = build / 'clangd' / context_name
    output.mkdir(parents=True, exist_ok=True)
    path = output / 'compile_commands.json'
    content = json.dumps(database, indent=2) + '\n'
    if path.exists() and path.read_text() == content:
        return
    temporary = output / 'compile_commands.json.tmp'
    temporary.write_text(content)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, required=True)
    options = parser.parse_args()
    build = options.build_dir.resolve()
    source = Path(__file__).resolve().parents[1]
    entries = json.loads((build / 'compile_commands.json').read_text())
    qt_headers = [*sorted((source / 'qt').rglob('*.hpp')), source / 'platform/environment.hpp']
    test_headers = sorted((source / 'tests').rglob('*.hpp'))

    write_header_database(build, entries, qt_headers, source / 'qt/application.cpp', 'qt')
    write_header_database(build, entries, test_headers, source / 'tests/quick_test.cpp', 'tests')


if __name__ == '__main__':
    main()
