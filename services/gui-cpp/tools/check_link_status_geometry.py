import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shlex
import struct
import subprocess

from check_peek_labels import protocol
from check_runtime_link import function


def sha(data):
    return hashlib.sha256(data).hexdigest()


cpp = r'''
#include "presentation/link_status_geometry.hpp"
#include <cstdio>
#include <cstdlib>
using namespace telar::gui;
template<typename T> T read() {
    T value{};
    if (std::fread(&value, sizeof(value), 1, stdin) != 1) { std::exit(2); }
    return value;
}
template<typename T> void write(T value) {
    if (std::fwrite(&value, sizeof(value), 1, stdout) != 1) { std::exit(3); }
}
void rect(Rect value) {
    write(value.x); write(value.y); write(value.width); write(value.height);
}
int main() {
    while (std::getchar() != EOF) {
        const Rect area{read<float>(), read<float>(), read<float>(), read<float>()};
        ChromeMetrics chrome;
        chrome.ratio = read<float>();
        chrome.title = read<std::uint16_t>();
        const auto connected = read<unsigned char>() != 0;
        const auto detail = read<unsigned char>() != 0;
        const bool visible = !connected && area.width > 0 && area.height > 0;
        const auto geometry = visible ? LinkStatusGeometry::measure(area, chrome, detail) : LinkStatusGeometry{};
        write(static_cast<unsigned char>(visible));
        write(static_cast<unsigned char>(visible ? (detail ? 2 : 1) : 0));
        rect(geometry.bounds);
        write(visible ? LinkStatusGeometry::dim_alpha : 0.0F);
        rect(geometry.headline);
        rect(visible && detail ? geometry.detail : Rect{});
    }
}
'''


facade = r'''
const std = @import("std");
const OriginalRuntimeLink = @import("RuntimeLink.zig");
const data = struct { const RuntimeLink = OriginalRuntimeLink; };
const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
const Label = struct {
    text: []const u8, color: u8 = 0, bold: bool = false,
    face: enum { sans } = .sans, size: enum { title, body } = .title,
};
const Chrome = struct {
    ratio: f32, title: u16,
    fn text(self: Chrome, _: @TypeOf(@as(Label, undefined).size)) ?u16 { return self.title; }
    fn px(self: Chrome, value: f32) f32 { return value * self.ratio; }
};
const Context = struct {
    projection: struct {
        model: struct { runtime_link: OriginalRuntimeLink },
        geometry: struct { area: Rect },
    },
};
const Canvas = struct {
    chrome: Chrome,
    metrics: struct { pixel_height: u16 = 13 } = .{},
    theme: struct { palette: struct { text: u8 = 0, subtext0: u8 = 0 } = .{} } = .{},
    dim: bool = false, dim_rect: Rect = .{}, alpha: f32 = 0,
    rows: [2]Rect = .{ .{}, .{} }, row_count: u8 = 0,
    fn rect(_: *Canvas, area: Rect) Rect { return area; }
    fn dimAt(self: *Canvas, area: Rect, alpha: f32) !void {
        self.dim = true; self.dim_rect = area; self.alpha = alpha;
    }
    fn measure(_: *Canvas, _: Label) !f32 { return std.math.floatMax(f32); }
    fn textAt(self: *Canvas, area: Rect, _: Label) !u16 {
        self.rows[self.row_count] = area; self.row_count += 1; return 0;
    }
};
'''


main_zig = r'''
fn write(value: anytype) !void {
    var copy = value;
    for (std.mem.asBytes(&copy)) |byte| {
        if (putchar(byte) < 0) { return error.WriteFailed; }
    }
}
fn writeRect(area: Rect) !void {
    try write(area.x); try write(area.y); try write(area.width); try write(area.height);
}
pub fn main() !void {
    while (getchar() >= 0) {
        const area: Rect = .{ .x = try read(f32), .y = try read(f32), .width = try read(f32), .height = try read(f32) };
        const chrome: Chrome = .{ .ratio = try read(f32), .title = try read(u16) };
        const connected = try read(u8) != 0;
        const detail = try read(u8) != 0;
        var link: OriginalRuntimeLink = .{};
        link.phase = if (connected) .connected else .lost;
        link.name("host");
        if (detail) { link.fail("failure"); }
        const context: Context = .{ .projection = .{ .model = .{ .runtime_link = link }, .geometry = .{ .area = area } } };
        var canvas: Canvas = .{ .chrome = chrome };
        try (LinkStatus{ .context = &context }).draw(&canvas);
        try write(@as(u8, @intFromBool(canvas.dim)));
        try write(canvas.row_count);
        try writeRect(canvas.dim_rect); try write(canvas.alpha);
        for (canvas.rows) |row| { try writeRect(row); }
    }
}
'''


def fixtures():
    cases = []
    for ratio in [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]:
        for width, height in [(0, 0), (-1, 40), (40, -1), (1, 1), (47, 40), (48, 40), (49, 40), (100, 60), (1792, 1304)]:
            for title in [6, 13, 26, 100, 4096]:
                for connected, detail in [(False, False), (False, True), (True, False), (True, True)]:
                    cases.append([17.5, 42, width, height, ratio, title, connected, detail])
    randomizer = random.Random(0x4C47454F)
    for _ in range(4096):
        cases.append([randomizer.randrange(-200, 2000) / 4, randomizer.randrange(-200, 2000) / 4, randomizer.randrange(-20, 12000) / 4, randomizer.randrange(-20, 8000) / 4, randomizer.randrange(1, 64) / 8, randomizer.randrange(6, 4097), bool(randomizer.getrandbits(1)), bool(randomizer.getrandbits(1))])
    return cases


def main():
    parser = argparse.ArgumentParser(description='Compare LinkStatus row geometry against unchanged original draw/centred bodies')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = ['src/gui/widgets/LinkStatus.zig', 'src/model/connection/RuntimeLink.zig', 'services/gui-cpp/presentation/link_status_geometry.hpp', 'services/gui-cpp/tools/check_link_status_geometry.py', 'services/gui-cpp/tools/check_runtime_link.py', 'services/gui-cpp/tools/check_peek_labels.py']
    widget = (repository / sources[0]).read_text()
    for name in sources[:2]:
        (output / Path(name).name).write_bytes((repository / name).read_bytes())
    constants = '\n'.join(re.search(r'^const ' + name + r'.*?;$', widget, re.M).group() for name in ['dim_alpha', 'line_height_factor', 'line_gap', 'inset', 'max_headline_bytes'])
    body = constants + '\ncontext: *const Context,\n' + '\n'.join(function(widget, name) for name in ['draw', 'centred', 'headlineText'])
    (output / 'probe.zig').write_text(facade + '\nconst LinkStatus = struct {\n' + body + '\n};\n' + protocol + main_zig)
    (output / 'probe.cpp').write_text(cpp)
    zig_command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original-geometry')]
    database = json.loads((options.build_dir / 'compile_commands.json').read_text())
    entry = next(row for row in database if row['file'].endswith('/tools/runtime_link_probe.cpp'))
    original_command = shlex.split(entry['command'])
    cpp_command = []
    skip = False
    for token in original_command:
        if skip:
            skip = False
            continue
        if token == '-o':
            skip = True
        elif token not in ['-c', entry['file']]:
            cpp_command.append(token)
    cpp_command += ['-ffp-contract=off', str(output / 'probe.cpp'), '-o', str(output / 'cpp-geometry')]
    for name, command in [('reference', zig_command), ('cpp', cpp_command)]:
        with (output / (name + '-build.log')).open('w') as log:
            subprocess.run(command, cwd=entry['directory'], stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = fixtures()
    requests = b''.join(b'\0' + struct.pack('<5fHBB', *case) for case in cases)
    (output / 'requests.bin').write_bytes(requests)
    (output / 'fixtures.json').write_text(json.dumps(cases, indent=2) + '\n')
    outputs = {}
    for name in ['original', 'cpp']:
        result = subprocess.run([str(output / (name + '-geometry'))], input=requests, capture_output=True, check=True)
        (output / (name + '.bin')).write_bytes(result.stdout)
        (output / (name + '.stderr')).write_bytes(result.stderr)
        assert len(result.stdout) == len(cases) * 54
        outputs[name] = result.stdout
    differences = [dict(index=index, original=struct.unpack_from('<BB13f', outputs['original'], index * 54), cpp=struct.unpack_from('<BB13f', outputs['cpp'], index * 54)) for index in range(len(cases)) if outputs['original'][index * 54:(index + 1) * 54] != outputs['cpp'][index * 54:(index + 1) * 54]]
    (output / 'differences.json').write_text(json.dumps(differences, indent=2) + '\n')
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), commands=dict(zig=zig_command, cpp=cpp_command), cases=len(cases), different_cases=len(differences), input_sha256=sha(requests), output_sha256={name:sha(value) for name,value in outputs.items()}, source_sha256={name:sha((repository / name).read_bytes()) for name in sources}, sanitizer_environment={key:os.environ.get(key) for key in ['ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS']}, scope='Unchanged original draw, centred and headlineText with original RuntimeLink. Field-only Canvas/Context/Label facade records quads and text rows. Its measure returns floatMax to expose whole row geometry; physical area and resolved title size/ratio are inputs. Font measurement, clipping and native composition are separate gates.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    assert not differences


if __name__ == '__main__':
    main()
