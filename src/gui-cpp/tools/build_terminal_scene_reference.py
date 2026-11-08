import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def run(command, directory, log):
    result = subprocess.run(command, cwd=directory, capture_output=True, text=True, check=False)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'Reference build failed; see {log}')


def main():
    parser = argparse.ArgumentParser(description='Build historical C++ terminal scenes against the current probe, Qt and font libraries; public scene APIs must be compatible')
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--output-dir', required=True, type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'qt').mkdir()
    revision = subprocess.check_output(['git', 'rev-parse', '--verify', options.revision + '^{commit}'], cwd=root, text=True).strip()
    sources = {}
    adaptations = {}
    for name in ['text_scene.cpp', 'text_scene.hpp', 'terminal_scene.cpp', 'terminal_scene.hpp']:
        source = 'src/gui-cpp/qt/' + name
        contents = subprocess.check_output(['git', 'show', revision + ':' + source], cwd=root)
        original = contents
        if name == 'text_scene.hpp':
            contents = contents.replace(b'template <fonts::FontProvider FontSet>\nclass ChromeGlyphImages;', b'template <fonts::FontProvider FontSet, bool optical>\nclass ChromeGlyphImages;')
            contents = contents.replace(b'ChromeGlyphImages<ResidentFonts>', b'ChromeGlyphImages<ResidentFonts, false>')
        if contents != original:
            adaptations[source] = dict(original_sha256=hashlib.sha256(original).hexdigest(), built_sha256=hashlib.sha256(contents).hexdigest(),
                                       change='Specialize the historical glyph-cache forward declaration and member for the current standard cache policy; rendering bodies are unchanged.')
        (output / 'qt' / name).write_bytes(contents)
        sources[source] = hashlib.sha256(original).hexdigest()

    database = json.loads((build / 'compile_commands.json').read_text())
    objects = []
    commands = []
    for relative in ['tools/terminal_scene_probe.cpp', 'qt/text_scene.cpp', 'qt/terminal_scene.cpp']:
        row = next(row for row in database if Path(row['file']).as_posix().endswith('/' + relative))
        arguments = shlex.split(row['command'])
        source = root / 'src/gui-cpp' / relative if relative.startswith('tools/') else output / relative
        target = output / (source.stem + '.o')
        arguments[arguments.index('-o') + 1] = str(target)
        arguments[-1] = str(source)
        arguments.insert(1, '-I' + str(output))
        run(arguments, Path(row['directory']), output / (source.stem + '.log'))
        objects.append(str(target))
        commands.append(arguments)

    lines = subprocess.check_output(['ninja', '-t', 'commands', 'gui-terminal-scene-probe'], cwd=build, text=True).splitlines()
    link = next(line for line in reversed(lines) if ' -o gui-terminal-scene-probe ' in line)
    arguments = shlex.split(link)
    compiler = shlex.split(next(row['command'] for row in database if row['file'].endswith('/tools/terminal_scene_probe.cpp')))[0]
    start = arguments.index(compiler)
    end = arguments.index('&&', start) if '&&' in arguments[start:] else len(arguments)
    arguments = arguments[start:end]
    arguments = [objects[0] if name.endswith('/tools/terminal_scene_probe.cpp.o') else name for name in arguments]
    binary = output / 'gui-terminal-scene-probe-reference'
    arguments[arguments.index('-o') + 1] = str(binary)
    position = arguments.index('libgui-quick.a')
    arguments[position:position] = objects[1:]
    run(arguments, build, output / 'link.log')
    commands.append(arguments)
    manifest = dict(revision=revision, source_sha256=sources, compatibility_adaptations=adaptations, commands=commands,
                    probe_source_sha256=hashlib.sha256((root / 'src/gui-cpp/tools/terminal_scene_probe.cpp').read_bytes()).hexdigest(),
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    scope='Historical TextScene and TerminalScene with the current identical workload and dependency builds. Other scene helpers come from the current build; use a full historical build when those helpers are the experiment.')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(binary)


if __name__ == '__main__':
    main()
