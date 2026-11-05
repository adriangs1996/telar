"""Prepare a macOS diagnostic runtime scope overlay without changing production.

Compile the runtime main translation unit with -ivfsoverlay OUTPUT/overlay.json,
keeping the baseline's Release flags and libraries. Existing out-of-line objects
are not instrumented. Set TELAR_RUNTIME_PHASE_TRACE to an owned output prefix;
normal runtime shutdown writes PREFIX.PID.jsonl. Never use this build for timing
acceptance. Pair with build_runtime_phase_probe.py and runtime_scope_report.py.
"""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise ValueError(f'Missing or ambiguous instrumentation anchor: {before!r}')
    return source.replace(before, after)


def prepare(output, base=None):
    output = output.resolve()
    overlay = json.loads(base.read_text()) if base else dict(version=0, **{'use-external-names': False}, roots=[])
    roots = overlay['roots']
    if any(entry.get('type') != 'file' or not Path(entry['name']).is_absolute() for entry in roots):
        raise ValueError('Base overlay must contain absolute file roots')
    names = [entry['name'] for entry in roots]
    if len(set(names)) != len(names):
        raise ValueError('Duplicate base overlay roots')
    paths = {entry['name']: Path(entry['external-contents']) for entry in roots}
    if any(not path.is_absolute() for path in paths.values()):
        raise ValueError('Base overlay contents must be absolute')
    output.mkdir(parents=True, exist_ok=False)
    inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths.values()}
    if base:
        inputs[str(base.resolve())] = hashlib.sha256(base.read_bytes()).hexdigest()
    def read(relative):
        original = ROOT / relative
        path = paths.get(str(original), original)
        inputs[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        return path.read_text()
    def add(relative, name, source):
        target = output / name
        target.write_text(source)
        original = str(ROOT / relative)
        roots[:] = [entry for entry in roots if entry['name'] != original]
        roots.append(dict(type='file', name=original, **{'external-contents': str(target)}))
    terminal_path = 'services/runtime-cpp/terminal/terminal.hpp'
    terminal = read(terminal_path)
    for name, work in [('feed', 'bytes.size()'), ('refresh', 'screen.cells.size()')]:
        terminal = replace_once(terminal, f'TELAR_TRACE("terminal.{name}");',
                                f'TELAR_PHASE_TRACE("terminal.{name}", this, {work}, static_cast<std::uint64_t>(purpose_));')
    terminal = replace_once(terminal, '    checkGhostty(ghostty_render_state_update(render_state_.get(), terminal_.get()));',
                            '    TELAR_PHASE_TRACE("terminal.project", this, screen.cells.size(), static_cast<std::uint64_t>(purpose_));\n'
                            '    checkGhostty(ghostty_render_state_update(render_state_.get(), terminal_.get()));')
    for signature, name, work in [('std::size_t feedControl(std::span<const Byte> bytes)', 'control', 'bytes.size()'),
                                  ('void finishControlInput()', 'finish', '0')]:
        anchor = f'  {signature} {{\n'
        terminal = replace_once(terminal, anchor, anchor + f'    TELAR_PHASE_TRACE("terminal.{name}", this, {work}, static_cast<std::uint64_t>(purpose_));\n')
    add(terminal_path, 'terminal.hpp', terminal)
    frame_path = 'services/runtime-cpp/terminal/frame_sync.hpp'
    frame = replace_once(read(frame_path), 'TELAR_TRACE("frame_sync.prepare");',
                         'TELAR_PHASE_TRACE("frame_sync.prepare", this, screen.cells.size(), pane_id_);')
    add(frame_path, 'frame_sync.hpp', frame)
    add('services/runtime-cpp/diagnostics/trace.hpp', 'trace.hpp', read('tools/macos_runtime_scope_trace.hpp'))
    (output / 'overlay.json').write_text(json.dumps(overlay, indent=2) + '\n')
    generated = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in output.iterdir()}
    (output / 'manifest.json').write_text(json.dumps(dict(scope=__doc__, inputs=inputs, generated=generated), indent=2) + '\n')
    return output / 'overlay.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--base-overlay', type=Path)
    args = parser.parse_args()
    print(prepare(args.output, args.base_overlay))


if __name__ == '__main__':
    main()
