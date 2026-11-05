"""Build a diagnostic scroll probe with runtime counters around measured inputs.

The ordinary native observer and application binaries are unchanged. This probe
adds three resource queries inside the GUI lifetime; its timings cannot establish
performance acceptance. Use runtime_phase_report.py with the outer resource
receipt to validate process identity, action coverage and phase accounting.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from build_scroll_probe import build as build_scroll_probe


def replace_once(contents, before, after):
    if contents.count(before) != 1:
        raise ValueError(f'Runtime phase hook changed: {before}')
    return contents.replace(before, after)


def build(output):
    directory = Path(output).resolve()
    source = Path(__file__).resolve().parent
    build_scroll_probe(directory)
    (directory / 'build.json').rename(directory / 'scroll-build.json')
    for name in ('runtime_phase_probe.inc', 'macos_process_resources.h', 'macos_process_resources_json.h'):
        shutil.copy2(source / name, directory / name)
    path = directory / 'gui_tui_latency.m'
    contents = path.read_text()
    contents = replace_once(contents, '#include "gui_view.h"',
                            '#include "gui_view.h"\n#include "runtime_phase_probe.inc"')
    contents = replace_once(contents, '    if(!count)input_class=NSStringFromClass(target.class);',
                            '    if(!count){runtime_phase_prepare();input_class=NSStringFromClass(target.class);}')
    contents = replace_once(contents, '        getrusage(RUSAGE_SELF, &measurement_start_usage);',
                            '        runtime_phase_begin();\n        getrusage(RUSAGE_SELF, &measurement_start_usage);')
    contents = replace_once(contents, '    finished=YES;',
                            '    runtime_phase_end([[display_directory stringByAppendingPathComponent:@"runtime-phase.json"] fileSystemRepresentation]);\n    finished=YES;')
    path.write_text(contents)
    path = directory / 'gui_tui_latency.py'
    contents = replace_once(path.read_text(),
                            "            identity = runtime_identity(directory / 'runtime.sock', runtime)",
                            "            identity = runtime_identity(directory / 'runtime.sock', runtime)\n"
                            "            launch_env['TGB_RUNTIME_PHASE_PID'] = str(identity['pid'])")
    path.write_text(contents)
    command = ['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
               '-framework', 'QuartzCore', '-framework', 'Metal',
               str(directory / 'gui_tui_latency.m'), '-o', str(directory / 'probe.dylib')]
    with (directory / 'phase-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy2(__file__, directory / Path(__file__).name)
    (directory / 'build.json').write_text(json.dumps(dict(
        scope='Diagnostic only. Runtime PID comes from the socket-verified identity; three snapshots separate setup, warmup and measured inputs.',
        command=command,
        sha256={file.name: hashlib.sha256(file.read_bytes()).hexdigest()
                for file in directory.iterdir() if file.is_file()},
    ), indent=2) + '\n')
    return directory / 'probe.dylib'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    print(build(parser.parse_args().output))
