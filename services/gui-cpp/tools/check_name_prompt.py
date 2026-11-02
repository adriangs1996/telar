import argparse
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_history_card import protocol


canvas = r'''
const Rect = @import("cellgrid").Rect;
const Palette = struct { panel_bg: u8 = 0, accent: u8 = 0, subtext0: u8 = 0 };
const Theme = struct { palette: Palette = .{} };
const Text = struct { text: []const u8, color: u8, bold: bool = false };
const Canvas = @This();
theme: Theme = .{},
title: Rect = .{},
field: Rect = .{},
footer: Rect = .{},
pub fn covering(_: Canvas, color: u8) u8 { return color; }
pub fn rect(_: Canvas, area: Rect) Rect { return area; }
pub fn fill(_: *Canvas, _: Rect, _: u8) !void {}
pub fn border(_: *Canvas, _: Rect, _: u8) !void {}
pub fn text(self: *Canvas, area: Rect, value: Text) !void {
    if (value.bold) self.title = area else self.footer = area;
}
'''

field = r'''
const Rect = @import("cellgrid").Rect;
const Canvas = @import("Canvas.zig");
const Prompt = @import("model").Prompt;
const TextField = @This();
area: Rect,
pub fn fromPrompt(_: *const Prompt, area: Rect, _: enum { name }) TextField {
    return .{ .area = area };
}
pub fn draw(self: TextField, target: *Canvas) !void { target.field = self.area; }
'''

reference = r'''
const io = @import("protocol.zig");
const Rect = @import("cellgrid").Rect;
const Canvas = @import("Canvas.zig");
const Modal = @import("overlays/Modal.zig");
const NamePrompt = @import("overlays/NamePrompt.zig");
const Prompt = @import("model").Prompt;
fn rectangle(area: Rect) !void {
    const visible: Rect = if (area.isEmpty()) .{} else area;
    try io.write(visible.x);
    try io.write(visible.y);
    try io.write(visible.w);
    try io.write(visible.h);
}
pub fn main() !void {
    while (io.operation() != -1) {
        const width = try io.read(u16);
        const height = try io.read(u16);
        const area = Modal.bounds(.{ .w = width, .h = height }, .{ .w = REQUEST_WIDTH, .h = REQUEST_HEIGHT });
        var drawing: Canvas = .{};
        const prompt: Prompt = .{};
        try (NamePrompt{ .area = area, .prompt = &prompt, .title = "Machine prompt" }).draw(&drawing);
        try rectangle(area);
        try rectangle(drawing.title);
        try rectangle(drawing.field);
        try rectangle(drawing.footer);
    }
}
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description='Compare name-prompt cell geometry with unchanged Zig Modal and NamePrompt drawing')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'overlays').mkdir()
    originals = ['lib/cellgrid/Rect.zig', 'src/gui/widgets/overlays/Modal.zig', 'src/gui/widgets/overlays/NamePrompt.zig', 'src/gui/widgets/overlays/modal_widget.zig']
    for name, destination in zip(originals[:3], ['Rect.zig', 'overlays/Modal.zig', 'overlays/NamePrompt.zig']):
        shutil.copy2(repository / name, output / destination)
    composition = (repository / originals[-1]).read_text()
    wanted = re.search(r'else => Modal.bounds\(host, \.\{ \.w = (\d+), \.h = (\d+) \}\)', composition)
    assert wanted
    (output / 'composition.zig').write_text(composition)
    (output / 'Canvas.zig').write_text(canvas)
    (output / 'TextField.zig').write_text(field)
    (output / 'model.zig').write_text('pub const Prompt = struct {};\n')
    (output / 'cellgrid.zig').write_text('pub const Rect = @import("Rect.zig");\n')
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (output / 'probe.zig').write_text(reference.replace('REQUEST_WIDTH', wanted[1]).replace('REQUEST_HEIGHT', wanted[2]))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'cellgrid', '--dep', 'model', '-Mroot=' + str(output / 'probe.zig'), '-Mcellgrid=' + str(output / 'cellgrid.zig'), '-Mmodel=' + str(output / 'model.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = list(itertools.product(range(97), range(33)))
    cases.extend(itertools.product([0, 1, 2, 3, 4, 12, 13, 64, 65, 65535], [0, 1, 2, 3, 6, 7, 8, 65535]))
    generator = random.Random(0x4D414348)
    cases.extend((generator.randrange(65536), generator.randrange(65536)) for _ in range(2048))
    payload = b''.join(b'\1' + struct.pack('<HH', *case) for case in cases)
    (output / 'input.bin').write_bytes(payload)
    binaries = dict(original=output / 'original', cpp=options.build_dir.resolve() / 'gui-name-prompt-probe')
    results = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / (name + '-output.bin')).write_bytes(result.stdout)
        (output / (name + '-run.log')).write_bytes(result.stderr)
        results[name] = result.stdout
    assert len(results['original']) == len(cases) * 32
    if results['original'] != results['cpp']:
        mismatches = [dict(index=index, host=case, original=struct.unpack('<16H', results['original'][index*32:(index+1)*32]), cpp=struct.unpack('<16H', results['cpp'][index*32:(index+1)*32])) for index, case in enumerate(cases) if results['original'][index*32:(index+1)*32] != results['cpp'][index*32:(index+1)*32]]
        (output / 'mismatches.json').write_text(json.dumps(mismatches, indent=2) + '\n')
        raise RuntimeError(f'{len(mismatches)} geometry differences')
    report = dict(cases=len(cases), output_bytes=len(results['cpp']), input_sha256=sha(output / 'input.bin'), output_sha256=sha(output / 'cpp-output.bin'), source_sha256={name:sha(repository / name) for name in originals}, scope='Cell geometry from unchanged original bounds/draw functions. Native paint, font and prompt editing are not covered. Empty rectangles are encoded as zero, since they draw no region.', command=command)
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
