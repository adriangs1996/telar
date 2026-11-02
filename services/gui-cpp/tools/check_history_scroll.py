import argparse
import datetime
import hashlib
import itertools
import json
import math
from pathlib import Path
import random
import struct
import subprocess

from check_history_card import protocol
from check_notification_center import function_source, run


facades = r'''
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Prompt = struct {
    generation: u64 = 0, inspect: bool = false,
    pub fn inspecting(self: *const @This()) bool { return self.inspect; }
};
pub const Names = struct {
    prompt: Prompt = .{},
    pub fn currentConst(self: *const @This()) ?*const Prompt { return &self.prompt; }
};
pub const History = struct {
    phase: enum { ready, loading } = .ready, revision: u64 = 0,
    pub fn version(self: *const @This()) u64 { return self.revision; }
};
pub const Target = struct {
    id: struct { generation: u64 = 0 } = .{}, bounds: Rect = .{},
    action: union(enum) { text_field, history: union(enum) { select: struct { revision: u64 } } } = .text_field,
};
pub const Registry = struct { targets: [2]Target = .{ .{}, .{} }, len: usize = 0 };
pub const Maps = struct {
    registry: Registry = .{},
    pub fn presented(self: *const @This()) *const Registry { return &self.registry; }
};
pub const Widgets = struct {
    history_scroll_remainder: f64 = 0, history_scroll_generation: u64 = 0,
    history_scroll_inspecting: bool = false,
    dispatcher: struct { maps: Maps = .{} } = .{},
};
pub const Overlays = struct {
    bounds: Rect = .{},
    pub fn presented(self: *const @This()) struct { native_modal: ?Rect } { return .{ .native_modal = self.bounds }; }
};
pub const WindowModel = struct {
    widgets: Widgets = .{}, overlays: Overlays = .{},
    pointer: struct { geometry: struct { size: struct { cell_height_px: u32 = 1 } = .{} } = .{} } = .{},
};
pub const event_module = struct {
    pub const Input = union(enum) {
        scroll: struct { x: f64, y: f64, delta_y: f64, precise: bool, phase: enum { none, begin, update, end, cancel } },
        pointer: struct { x: f64, y: f64, kind: enum { scroll_up, scroll_down } },
    };
};
pub const client = struct {
    pub const Client = struct {
        model: struct { name_prompt: Names = .{}, history_palette: History = .{} } = .{}, steps: i32 = 0,
    };
    pub const history_palette = struct {
        pub fn scrollHistoryInspection(app: *Client, lines: i16) !void { app.steps += lines; }
    };
};
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const f = @import("facades.zig");
const WindowModel = f.WindowModel;
const client = f.client;
const event_module = f.event_module;
const Bands = struct { const Rect = f.Rect; __WITHIN__ };
fn command(_: *WindowModel, app: *client.Client, action: enum { move_up, move_down }) !void {
    app.steps += if (action == .move_up) -1 else 1;
}
__SCROLL_HISTORY__
pub fn main() !void {
    var model: WindowModel = .{};
    var app: client.Client = .{};
    while (true) {
        const operation = io.read(u8) catch return;
        if (operation == 0) { model = .{}; continue; }
        app.model.name_prompt.prompt.generation = try io.read(u64);
        app.model.history_palette.revision = try io.read(u64);
        app.model.history_palette.phase = if (try io.read(u8) != 0) .ready else .loading;
        app.model.name_prompt.prompt.inspect = try io.read(u8) != 0;
        model.overlays.bounds = try io.readRect();
        const generation = try io.read(u64);
        const revision = try io.read(u64);
        const row_height = try io.read(f64);
        model.pointer.geometry.size.cell_height_px = try io.read(u32);
        const delivered = try io.read(u8) != 0;
        const has_rows = try io.read(u8) != 0;
        const registry = &model.widgets.dispatcher.maps.registry;
        registry.len = 0;
        if (delivered) {
            registry.targets[registry.len] = .{ .id = .{ .generation = generation }, .action = .text_field };
            registry.len += 1;
        }
        if (has_rows) {
            registry.targets[registry.len] = .{ .id = .{ .generation = generation }, .bounds = .{ .height = @floatCast(row_height) }, .action = .{ .history = .{ .select = .{ .revision = revision } } } };
            registry.len += 1;
        }
        const x = try io.read(f64);
        const y = try io.read(f64);
        const delta = try io.read(f64);
        const precise = try io.read(u8) != 0;
        const phase = try io.read(u8);
        const event: event_module.Input = if (operation == 1)
            .{ .scroll = .{ .x = x, .y = y, .delta_y = delta, .precise = precise, .phase = @enumFromInt(phase) } }
        else .{ .pointer = .{ .x = x, .y = y, .kind = if (operation == 2) .scroll_up else .scroll_down } };
        app.steps = 0;
        _ = try scrollHistory(&model, &app, event);
        try io.write(app.steps);
    }
}
'''


def prepare(repository, output):
    routing = (repository / 'src/gui/widgets/interaction/routing.zig').read_text()
    bands = (repository / 'src/gui/widgets/Bands.zig').read_text()
    source = reference.replace('__WITHIN__', function_source(bands, 'within'))
    source = source.replace('__SCROLL_HISTORY__', function_source(routing, 'scrollHistory'))
    (output / 'probe.zig').write_text(source)
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text(facades)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def record(delta=1, generation=1, revision=1, ready=True, inspecting=False,
           bounds=(20, 30, 200, 150), surface_generation=None, surface_revision=None,
           row_height=32, cell_height=20, delivered=True, has_rows=True,
           position=(40, 50), precise=False, phase=0, operation=1):
    return struct.pack('<BQQBB4fQQdIBBdddBB', operation, generation, revision, ready, inspecting, *bounds,
                       generation if surface_generation is None else surface_generation,
                       revision if surface_revision is None else surface_revision,
                       f32(row_height), cell_height, delivered, has_rows, *position, delta, precise, phase)


def fixtures():
    yield b'\0'
    yield record(delta=.5)
    yield record(delta=.5, position=(math.nextafter(20, -math.inf), 50))
    yield record(delta=.5)
    yield b'\0'
    yield record(inspecting=True, has_rows=False, surface_revision=0)
    for ready, inspecting, delivered, has_rows, phase in itertools.product([False, True], [False, True], [False, True], [False, True], range(5)):
        yield b'\0'
        for delta in [.25, .75, -.5, 1, -32.5, 65, math.inf, math.nan, .5]:
            yield record(delta=delta, ready=ready, inspecting=inspecting, delivered=delivered, has_rows=has_rows, phase=phase)
    for bounds in [(20, 30, 200, 150), (.1, .2, .2, .3), (16_777_216, 30, 1, 150), (0, 0, 0, 0)]:
        left, top, width, height = [f32(value) for value in bounds]
        for boundary in [left, left + width]:
            for x in [math.nextafter(boundary, -math.inf), boundary, math.nextafter(boundary, math.inf)]:
                yield b'\0'
                yield record(bounds=bounds, position=(x, top + height / 2))
        for boundary in [top, top + height]:
            for y in [math.nextafter(boundary, -math.inf), boundary, math.nextafter(boundary, math.inf)]:
                yield b'\0'
                yield record(bounds=bounds, position=(left + width / 2, y))
    generator = random.Random(0x5C2011)
    for batch in range(100):
        yield b'\0'
        for _ in range(128):
            generation = 1 + batch % 3
            revision = 1 + batch % 5
            yield record(delta=generator.choice([-.75, -.5, -.25, .125, .5, .75, 1.5, 64, -100]),
                         generation=generation, revision=revision, ready=generator.randrange(8) != 0,
                         inspecting=batch % 2 == 0, delivered=generator.randrange(8) != 0,
                         has_rows=generator.randrange(4) != 0, precise=generator.randrange(3) != 0,
                         surface_generation=generator.choice([generation, generation, generation + 1]),
                         surface_revision=generator.choice([revision, revision, revision + 1]),
                         row_height=generator.choice([0, 1, 20, 32, 64, 128]), cell_height=generator.choice([0, 1, 20, 40]),
                         phase=generator.randrange(5), operation=generator.choice([1, 1, 1, 2, 3]))


def main():
    parser = argparse.ArgumentParser(description='Compare bounded history wheel routing with the unchanged original Zig handler')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--cpp-probe', type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    executable = options.cpp_probe.resolve() if options.cpp_probe else options.build_dir.resolve() / 'gui-history-scroll-probe'
    actual = run(executable, payload, output, 'cpp')
    if expected != actual:
        offset = next((index for index, (a, b) in enumerate(zip(expected, actual)) if a != b), min(len(expected), len(actual)))
        raise RuntimeError(f'History scroll differs at event {offset // 4}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_scroll_probe.cpp')]
    sources += [repository / path for path in ['src/gui/widgets/interaction/routing.zig', 'src/gui/widgets/Bands.zig', 'services/gui-cpp/input/history_scroll.hpp', 'services/gui-cpp/input/wheel_accumulator.hpp']]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=sum(case != b'\0' for case in cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), output_bytes=len(actual), reference_command=command, source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, scope='Original bounds, delivered generation/revision gates, row/cell units, fractional wheel state, phase resets and routed line counts. Real selection/paging mutations, Qt event delivery, pixels and performance require separate checks.')
    (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Matched', result['records'], 'original history scroll events')


if __name__ == '__main__':
    main()
