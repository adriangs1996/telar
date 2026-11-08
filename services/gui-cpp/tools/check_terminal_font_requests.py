"""Compare source-extracted GUI font requests with real coverage and normalization.

Only requestRowFonts and the FontCollection installation block are transplanted.
The catalog records requests; native discovery, async completion and rendering are
outside this oracle. Both variants use the configured build's common libraries.
"""

import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shlex
import struct
import subprocess


FACADE = r'''
#include "fonts/face.hpp"
#include "fonts/font_coverage.hpp"
#include "fonts/font_role.hpp"
#include "terminal/screen.hpp"
#include <QString>
#include <array>
#include <memory>
#include <string>
#include <vector>
using namespace telar;
using namespace telar::gui;
struct ResidentFonts {
  fonts::Face primary;
  explicit ResidentFonts(std::span<const Byte> bytes) : primary(bytes) {}
  const fonts::Face &face(fonts::FontRole) { return primary; }
  static std::shared_ptr<ResidentFonts> shared(const std::shared_ptr<ResidentFonts> &collection) { return collection; }
};
struct Catalog {
  struct Request { fonts::FontRole role; std::string text; };
  std::shared_ptr<ResidentFonts> current;
  std::vector<Request> requests;
  const std::shared_ptr<ResidentFonts> &collection() const { return current; }
  void request(std::string_view text, fonts::FontRole role) { requests.push_back({role, std::string{text}}); }
};
class TerminalItem {
public:
  std::shared_ptr<ResidentFonts> font_collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  Catalog *font_catalog_ = nullptr;
  CACHE_MEMBERS
  void requestRowFonts(std::span<const CellValue> cells);
  void install(Catalog *catalog) { INSTALL_BLOCK }
};
REQUEST_BODY
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def variant(source, header):
    members = ''
    if 'enum class AsciiCoverage' in header:
        members = '\n'.join([
            block(header, 'enum class AsciiCoverage') + ';',
            re.search(r'static constexpr std::size_t ascii_count = [^;]+;', header).group(),
            re.search(r'std::array<AsciiCoverage, ascii_count> font_ascii_[^;]*;', header).group(),
        ])
    return (FACADE.replace('CACHE_MEMBERS', members)
            .replace('INSTALL_BLOCK', block(source, 'if (font_collection_ != catalog->collection())'))
            .replace('REQUEST_BODY', block(source, 'void TerminalItem::requestRowFonts(')))


def build_probe(build, source, output):
    output.mkdir()
    sources = {}
    for name in ('terminal_item.cpp', 'terminal_item.hpp'):
        path = source / name
        sources[name] = dict(path=str(path), sha256=digest(path))
        (output / name).write_bytes(path.read_bytes())
    generated = variant((source / 'terminal_item.cpp').read_text(), (source / 'terminal_item.hpp').read_text())
    header = output / 'terminal_font_requests_variant.hpp'
    header.write_text(generated)
    probe = Path(__file__).with_name('terminal_font_requests_probe.cpp')
    database = json.loads((build / 'compile_commands.json').read_text())
    row = next(row for row in database if row['file'].endswith('/qt/terminal_item.cpp'))
    command = row.get('arguments') or shlex.split(row['command'])
    compiler = command[0]
    obj = output / 'probe.o'
    command[command.index('-o') + 1] = str(obj)
    command[-1] = str(probe)
    command.insert(1, '-I' + str(output))
    with (output / 'compile.log').open('w') as log:
        subprocess.run(command, cwd=row['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
    lines = subprocess.check_output(['ninja', '-t', 'commands', 'gui-terminal-scene-probe'], cwd=build, text=True).splitlines()
    line = next(line for line in reversed(lines) if ' -o gui-terminal-scene-probe ' in line)
    link = shlex.split(line)
    start = link.index(compiler)
    end = link.index('&&', start) if '&&' in link[start:] else len(link)
    link = link[start:end]
    link = [str(obj) if arg.endswith('/tools/terminal_scene_probe.cpp.o') else arg for arg in link]
    binary = output / 'probe'
    link[link.index('-o') + 1] = str(binary)
    with (output / 'link.log').open('w') as log:
        subprocess.run(link, cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True)
    libraries = {str((build / arg).resolve()): digest(build / arg) for arg in link
                 if (arg.endswith(('.a', '.so', '.dylib')) or '.framework/' in arg) and (build / arg).is_file()}
    return binary, dict(sources=sources, generated_sha256=digest(header), probe_source_sha256=digest(probe),
                        binary_sha256=digest(binary), commands=[command, link], libraries=libraries)


def corpus():
    payload = bytearray()
    records = 0
    cell_count = 0

    def row(font, cells):
        nonlocal records, cell_count
        payload.extend(struct.pack('<II', font, len(cells)))
        for text, width, flags in cells:
            if len(text) > 16:
                raise ValueError('Fixture cell exceeds CellValue capacity')
            payload.extend(struct.pack('<BBH', width, len(text), flags))
            payload.extend(text)
        records += 1
        cell_count += len(cells)

    def emit(font, texts):
        for offset in range(0, len(texts), 128):
            cells = [(text, 1, 0) for text in texts[offset:offset + 128]]
            for _ in range(2):
                row(font, cells)

    for font in [0, 1, 0, 4, 0, 2, 1, 3, 0, 4, 3, 1, 0]:
        for _ in range(3):
            emit(font, [bytes([value]) for value in range(256)])
    randomizer = random.Random(20261103)
    for font in range(5):
        emit(font, [bytes([a, b]) for a in range(256) for b in range(256)])
        scalars = [0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff,
                   0x200c, 0x200d, 0xfe00, 0xfe0f, 0xe0100, 0xe01ef]
        scalars += [randomizer.randrange(0x110000) for _ in range(5000)]
        emit(font, [chr(value).encode('utf8') for value in scalars if not 0xd800 <= value <= 0xdfff])
        emit(font, [b'', b'A\x00', b'\xc0\xaf', b'\xe0\x80\x80', b'\xf4\x90\x80\x80',
                    b'\xed\xa0\x80', b'\xf0\x9f', b'\xff' * 16, 'e\u0301'.encode(),
                    '\u200d\ufe0f'.encode(), '👨\u200d💻'.encode()])
        for _ in range(256):
            cells = []
            for _ in range(64):
                text = bytes(randomizer.randrange(256) for _ in range(randomizer.randrange(17)))
                cells.append((text, randomizer.randrange(3), randomizer.randrange(65536)))
            row(font, cells)
            row(font, cells)
    return payload, records, cell_count


def request_count(data, records):
    offset = 0
    requests = 0
    for _ in range(records):
        count, = struct.unpack_from('<I', data, offset)
        offset += 4
        requests += count
        for _ in range(count):
            _, size = struct.unpack_from('<II', data, offset)
            offset += 8
            if offset + size > len(data):
                raise ValueError('Truncated request text')
            offset += size
    if offset != len(data):
        raise ValueError('Trailing request output')
    return requests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--reference', required=True, type=Path, help='Directory containing reference terminal_item.cpp/.hpp')
    parser.add_argument('--candidate', required=True, type=Path, help='Directory containing candidate terminal_item.cpp/.hpp')
    parser.add_argument('--output-dir', required=True, type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fonts = [root / 'assets' / name for name in
             ('JetBrainsMono-Regular.ttf', 'SymbolsNerdFontMono-Regular.ttf', 'IBMPlexSans-Regular.ttf', 'IBMPlexSans-SemiBold.ttf')]
    fonts.append(root / 'services/gui-cpp/tests/fixtures/metrics-variable.ttf')
    payload, records, cells = corpus()
    (output / 'input.bin').write_bytes(payload)
    manifest = dict(scope=__doc__, records=records, cells=cells, input_sha256=hashlib.sha256(payload).hexdigest(),
                    fonts={str(path): digest(path) for path in fonts}, driver_sha256=digest(Path(__file__)), variants={})
    common = ('terminal/screen.hpp', 'fonts/font_coverage.hpp', 'fonts/face.hpp', 'fonts/face.cpp',
              'core/unicode_scalar.hpp', 'fonts/font_role.hpp')
    manifest['common_sources'] = {name: digest(root / 'services/gui-cpp' / name) for name in common}
    binaries = {}
    for label, source in (('reference', options.reference), ('candidate', options.candidate)):
        binary, receipt = build_probe(options.build_dir.resolve(), source.resolve(), output / label)
        binaries[label] = binary
        manifest['variants'][label] = receipt
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    expected = None
    results = {}
    for label, binary in binaries.items():
        with (output / (label + '.bin')).open('wb') as stdout, (output / (label + '.stderr')).open('wb') as stderr:
            subprocess.run([str(binary), *map(str, fonts)], input=payload, stdout=stdout, stderr=stderr, check=True, timeout=180)
        data = (output / (label + '.bin')).read_bytes()
        count = request_count(data, records)
        if expected is not None and data != expected:
            raise ValueError('Fallback request roles or text bytes differ; both streams are retained')
        if digest(binary) != manifest['variants'][label]['binary_sha256']:
            raise ValueError('Probe changed during comparison')
        expected = data
        results[label] = dict(bytes=len(data), requests=count, sha256=hashlib.sha256(data).hexdigest())
        print(label, results[label], flush=True)
    (output / 'result.json').write_text(json.dumps(dict(passed=True, records=records, cells=cells, results=results), indent=2) + '\n')


if __name__ == '__main__':
    main()
