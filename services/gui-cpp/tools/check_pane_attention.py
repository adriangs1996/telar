import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_agent_clocks import enum_source
from check_notification_center import function_source, run


canvas_source = r'''
const Rect = @import("gfx").Rect;
const Color = @import("cellgrid").Color;
const Ring = @import("Ring.zig");
const Canvas = @This();
pub const Paint = extern struct { bounds: Rect, radius: f32, border: f32, fill: Color, border_color: Color };
const Recorder = struct {
    paint: ?Paint = null,
    pub fn pushRounded(self: *Recorder, bounds: Rect, style: anytype) !void {
        self.paint = .{ .bounds = bounds, .radius = style.radius, .border = style.border, .fill = .{ .r = style.fill.r, .g = style.fill.g, .b = style.fill.b, .a = style.fill.a }, .border_color = style.border_color };
    }
};
chrome: struct { ratio: f32, pub fn px(self: @This(), value: f32) f32 { return value * self.ratio; } },
theme: struct { palette: @import("model").Palette, terminal: struct { foreground: Color } },
animation: ?*@import("animate").FrameClock = null,
quads: Recorder = .{},
pub fn color(_: Canvas, value: Color, _: Color) Color { return value; }
__RING_AT__
__CLAMP__
'''

reference_source = r'''
const std = @import("std");
const data = @import("model");
const Canvas = @import("Canvas.zig");
const Decor = @import("PaneDecorations.zig");
const Fades = @import("RingFades.zig");
const FrameClock = @import("animate").FrameClock;
const Rect = @import("gfx").Rect;
const Color = @import("cellgrid").Color;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn key() !data.AgentKey { return .{ .pane_id = try read(u64), .pane_generation = try read(u64) }; }
fn status(clock: *const FrameClock, fades: *const Fades) !void {
    try write(@as(u8, @intFromBool(clock.deadline_ns != null)));
    try write(clock.deadline_ns orelse 0);
    try write(@as(u32, @intCast(fades.len)));
}
pub fn main() !void {
    var fades: Fades = .{};
    var clock: FrameClock = .{};
    while (true) {
        const operation = getchar(); if (operation < 0) break;
        switch (operation) {
            0 => { const now = try read(u64); clock.interval_ns = try read(u64); clock.begin(now); fades.begin(); },
            1 => { const alpha = fades.alpha(try key(), &clock); try write(alpha); try status(&clock, &fades); },
            2 => { fades.end(); try status(&clock, &fades); },
            3 => {
                const bounds = try read(Rect);
                const ratio = try read(f32);
                const color = try read(Color);
                const identity = try key();
                const animated = try read(u8) != 0;
                var canvas: Canvas = .{ .chrome = .{ .ratio = ratio }, .theme = .{ .palette = .{ .teal = color, .green = color, .yellow = color, .red = color, .overlay1 = color }, .terminal = .{ .foreground = color } }, .animation = if (animated) &clock else null };
                try (Decor{ .rings = &fades }).drawRing(&canvas, .{ .view = .{ .frame = bounds }, .status = .blocked, .key = identity });
                try write(@as(u8, @intFromBool(canvas.quads.paint != null)));
                if (canvas.quads.paint) |paint| { try write(paint); }
                try status(&clock, &fades);
            },
            4 => { fades = .{}; clock = .{}; },
            else => return error.UnknownOperation,
        }
    }
}
'''


def prepare(root, work):
    source = root/'src/gui/widgets'
    for name in ['RingFades', 'RingFade', 'RingSpec', 'Ring']:
        shutil.copy2(source/(name+'.zig'), work/(name+'.zig'))
    (work/'gfx.zig').write_text('pub const Rect = extern struct { x:f32, y:f32, width:f32, height:f32 };\n')
    (work/'cellgrid.zig').write_text('pub const Color = extern struct { r:f32=0, g:f32=0, b:f32=0, a:f32=1 };\n')
    (work/'model.zig').write_text('''const Color = @import("cellgrid").Color;
pub const AgentKey = struct { pane_id:u64, pane_generation:u64 };
pub const LayoutView = struct { frame:@import("gfx").Rect };
pub const Palette = struct { teal:Color, green:Color, yellow:Color, red:Color, overlay1:Color };
''')
    types = (root/'src/core/schema/types.zig').read_text()
    (work/'core.zig').write_text(re.search(r'pub const max_panes_per_tab = .*?;', types).group()+'\n'+enum_source(types, 'AgentStatus'))
    original_canvas = (source/'Canvas.zig').read_text()
    canvas = canvas_source.replace('__RING_AT__', function_source(original_canvas, 'ringAt')).replace('__CLAMP__', function_source(original_canvas, 'clampRadius'))
    (work/'Canvas.zig').write_text(canvas)
    decoration_source = (source/'PaneDecorations.zig').read_text()
    ring = function_source(decoration_source, 'ring')
    constants = '\n'.join(re.search(r'pub const '+name+r': f32 = .*?;', decoration_source).group() for name in ['ring_width', 'frame_radius'])
    (work/'PaneDecorations.zig').write_text('''const Canvas = @import("Canvas.zig"); const Rect = @import("gfx").Rect; const RingSpec = @import("RingSpec.zig"); const attention = @import("attention.zig"); const PaneDecorations = @This();
__CONSTANTS__
rings: *@import("RingFades.zig"),
fn frameRect(_:PaneDecorations, _: *const Canvas, view:@import("model").LayoutView) Rect { return view.frame; }
pub fn drawRing(self:PaneDecorations, canvas:*Canvas, spec:RingSpec) !void { try self.ring(canvas,spec); }
'''.replace('__CONSTANTS__', constants)+ring)
    color = function_source((source/'attention.zig').read_text(), 'statusColor')
    (work/'attention.zig').write_text('const data=@import("model"); const core=@import("telar-core"); const cellgrid=@import("cellgrid");\n'+color)
    (work/'probe.zig').write_text(reference_source)
    command = ['zig','build-exe','-O','ReleaseSafe','-lc','--dep','model','--dep','telar-core','--dep','gfx','--dep','cellgrid','--dep','animate',f'-Mroot={work/"probe.zig"}','--dep','gfx','--dep','cellgrid',f'-Mmodel={work/"model.zig"}',f'-Mtelar-core={work/"core.zig"}',f'-Mgfx={work/"gfx.zig"}',f'-Mcellgrid={work/"cellgrid.zig"}',f'-Manimate={root/"lib/animate/root.zig"}',f'-femit-bin={work/"original"}']
    with (work/'reference-build.log').open('w') as output:
        subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,check=True)
    return command


def frame(now, interval=16_666_667):
    return struct.pack('<BQQ', 0, now, interval)


def alpha(pane, generation):
    return struct.pack('<BQQ', 1, pane, generation)


def geometry(bounds, ratio, color, identity=(1, 1), animated=False):
    return struct.pack('<B9fQQB', 3, *bounds, ratio, *color, *identity, animated)


def fixtures():
    maximum = 2**64-1
    yield b'\x04'
    for now in [0, 1, 90_000_000, 180_000_000, 359_999_999, 360_000_000, 360_000_001]:
        yield frame(now)
        yield alpha(1, 1)
        yield alpha(1, 1)
        yield b'\x02'
    yield frame(400_000_000)
    yield b'\x02'
    yield frame(400_000_001)
    yield alpha(1, 1)
    yield alpha(1, 2)
    yield b'\x02'
    for now in [0, maximum-359_999_999, maximum-1, maximum]:
        yield b'\x04'
        yield frame(now)
        for pane in range(129):
            yield alpha(pane, maximum-pane)
        yield b'\x02'
        yield frame(min(maximum, now+180_000_000), maximum)
        for pane in reversed(range(129)):
            yield alpha(pane, maximum-pane)
        yield b'\x02'
    generator = random.Random(0x52494E47)
    now = 0
    yield b'\x04'
    for _ in range(4000):
        now += generator.choice([0, 1, 4_166_667, 8_333_334, 16_666_667, 360_000_000, 1_000_000_000])
        yield frame(now, generator.choice([1, 4_166_667, 8_333_334, 16_666_667, 100_000_000]))
        for _ in range(generator.choice([0, 1, 2, 8, 64, 129])):
            identity = (generator.randrange(80), generator.randrange(4))
            if generator.randrange(5):
                yield alpha(*identity)
            else:
                yield geometry((generator.random()*100, generator.random()*50, generator.choice([0, 1, 2, 5.5, 32, 648]), generator.choice([0, 1, 2, 8.25, 64, 920])), generator.choice([0.5, 0.75, 1, 1.25, 1.5, 2, 3]), (0.8, 0.6, 0.2, generator.choice([0, 0.25, 0.5, 1])), identity, True)
        yield b'\x02'
    for ratio in [0.5, 0.75, 1, 1.25, 1.5, 2, 3]:
        for width in [0, 1, 2, 5.5, 32, 648]:
            for height in [0, 1, 2, 8.25, 64, 920]:
                yield geometry((0.25, 2.5, width, height), ratio, (0.8, 0.6, 0.2, 0.5))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir',type=Path,default=Path(__file__).resolve().parents[1]/'out')
    parser.add_argument('--output-dir',type=Path,required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve();work.mkdir(parents=True,exist_ok=False)
    command = prepare(root,work)
    cases = list(fixtures());payload=b''.join(cases)
    (work/'input.bin').write_bytes(payload)
    expected=run(work/'original',payload,work,'original')
    actual=run(options.build_dir.resolve()/'gui-pane-attention-probe',payload,work,'cpp')
    if expected != actual:
        offset=next((index for index,pair in enumerate(zip(expected,actual)) if pair[0]!=pair[1]),min(len(expected),len(actual)))
        raise RuntimeError(f'Pane attention mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources=['src/gui/widgets/'+name+'.zig' for name in ['RingFades','RingFade','RingSpec','Ring','PaneDecorations','Canvas','attention']]+['lib/animate/Transition.zig','lib/animate/FrameClock.zig','services/gui-cpp/presentation/attention_fades.hpp','services/gui-cpp/presentation/pane_attention_geometry.hpp','services/gui-cpp/tools/pane_attention_probe.cpp','services/gui-cpp/tools/check_pane_attention.py']
    result=dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),operations=len(cases),frames=sum(case[0]==0 for case in cases),geometry_calls=sum(case[0]==3 for case in cases),input_sha256=hashlib.sha256(payload).hexdigest(),output_sha256=hashlib.sha256(actual).hexdigest(),source_sha256={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sources},generated_sha256={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in work.glob('*.zig')},reference_command=command,scope='Unchanged original RingFades, RingFade, RingSpec, Ring, FrameClock and Transition. The original PaneDecorations.ring, Canvas.ringAt, radius clamp and attention status color bodies execute unchanged against a precomputed frame facade and injected RGBA values. Compares alpha, bounded retention/pruning, saturated coalesced deadlines and ordered rounded-shape values. Does not establish native scheduling, installed colors, GPU pixels or comparative performance.')
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('Matched',result['operations'],'attention operations and',result['geometry_calls'],'ring paints:',result['output_sha256'])


if __name__=='__main__':
    main()
