import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_notification_center import function_source, run


reference = r'''
const std = @import("std");
const capacity = __CAPACITY__;
__LAYER_TYPE__
const below_background_limit: i32 = std.math.minInt(i32) / 2;
__LAYER__
const ImagePlacement = struct { pane_id: u64, virtual_id: u64, image_id: u32, layer: Layer, z_index: i32 };
const core = struct { const RectRect = struct {}; };
const PaneImages = struct {
    placements: [capacity]ImagePlacement = undefined,
    sources: [capacity]core.RectRect = undefined,
    placement_count: usize = 0,
    dropped: usize = 0,
};
__KEEP__
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn identityOrder(_: void, left: ImagePlacement, right: ImagePlacement) bool {
    if (left.pane_id != right.pane_id) return left.pane_id < right.pane_id;
    return left.virtual_id < right.virtual_id;
}
fn sameIdentity(left: ImagePlacement, right: ImagePlacement) bool {
    return left.pane_id == right.pane_id and left.virtual_id == right.virtual_id and left.image_id == right.image_id;
}
pub fn main() !void {
    var previous: PaneImages = .{};
    while (true) {
        if (getchar() < 0) return;
        var images: PaneImages = .{};
        const count = try read(u32);
        for (0..count) |_| {
            const pane = try read(u64); const virtual = try read(u64); const image = try read(u32);
            const placeholder = try read(u8) != 0; const z_index = try read(i32);
            keep(&images, .{.pane_id = pane, .virtual_id = virtual, .image_id = image, .layer = if (placeholder) .below_text else layer(z_index), .z_index = z_index}, .{});
        }
        const selected = images.placements[0..images.placement_count];
        std.mem.sort(ImagePlacement, selected, {}, identityOrder);
        var changed = previous.placement_count != images.placement_count;
        if (!changed) { for (selected, previous.placements[0..previous.placement_count]) |left, right| { if (!sameIdentity(left, right)) { changed = true; break; } } }
        try write(@as(u8, @intFromBool(changed)));
        try write(@as(u32, @intCast(images.placement_count)));
        try write(@as(u32, @intCast(images.dropped)));
        for (selected) |entry| {
            try write(entry.pane_id); try write(entry.virtual_id); try write(entry.image_id);
            try write(@as(u8, 1)); try write(@as(u8, 1));
        }
        previous = images;
    }
}
'''


def fixtures(capacity):
    generator = random.Random(0x51EC7)
    boundary = -(2**31) // 2
    edges = [-(2**31), boundary - 1, boundary, -1, 0, 1, 2**31 - 1]
    for size in [0, 1, capacity - 1, capacity, capacity + 1, capacity * 2, capacity * 4]:
        for mode in range(5):
            candidates = []
            for index in range(size):
                z_index = [0, index, -index, generator.choice(edges), generator.randrange(-(2**31), 2**31)][mode]
                candidates.append((index % 17 + 1, index + 1, generator.randrange(1, 65), generator.randrange(2), z_index))
            for _ in range(2):
                yield candidates
            generator.shuffle(candidates)
            yield candidates
    for _ in range(40):
        size = generator.randrange(capacity - 8, capacity * 2)
        candidates = [(index % 64 + 1, index + 1, generator.randrange(1, 65), generator.randrange(2), generator.choice(edges)) for index in range(size)]
        yield candidates
        yield [(catalog, virtual, image, placeholder, z_index) for catalog, virtual, image, placeholder, z_index in candidates if virtual % 3 != 0]


def main():
    parser = argparse.ArgumentParser(description='Compare the bounded placement selector against unchanged original Zig heap functions')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original = root / 'src/gui/image/pane_images.zig'
    display = root / 'lib/kitty_protocol/display.zig'
    layer = root / 'lib/kitty_protocol/Layer.zig'
    draw = root / 'lib/gfx/ImageDraw.zig'
    capacity = int(re.search(r'pub const capacity = (\d+);', draw.read_text())[1])
    functions = ['keep', 'paintsBelow', 'siftUp', 'siftDown', 'swapKept']
    layer_type = layer.read_text().split('pub const Layer', 1)[1]
    source = reference.replace('__CAPACITY__', str(capacity)).replace('__LAYER_TYPE__', 'pub const Layer' + layer_type).replace('__LAYER__', function_source(display.read_text(), 'layer')).replace('__KEEP__', '\n'.join(function_source(original.read_text(), name) for name in functions))
    (output / 'probe.zig').write_text(source)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    frames = list(fixtures(capacity))
    data = b''.join(b'\0' + struct.pack('<I', len(frame)) + b''.join(struct.pack('<QQIBi', *candidate) for candidate in frame) for frame in frames)
    (output / 'input.bin').write_bytes(data)
    expected = run(output / 'original', data, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-placement-selection-probe', data, output, 'cpp')
    if expected != actual:
        mismatch = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Placement selection differs at byte {mismatch}, output lengths {len(expected)} and {len(actual)}')
    sources = [original, display, layer, draw, root / 'services/gui-cpp/graphics/placement_selection.hpp', root / 'services/gui-cpp/graphics/image_draw_budget.hpp', root / 'services/gui-cpp/tools/placement_selection_probe.cpp', root / 'services/gui-cpp/tools/check_notification_center.py', root / 'services/gui-cpp/tools/check_task_labels.py', Path(__file__).resolve()]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), frames=len(frames), candidates=sum(map(len, frames)), capacity=capacity, input_sha256=hashlib.sha256(data).hexdigest(), original_output_sha256=hashlib.sha256(expected).hexdigest(), cpp_output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, reference_command=command, unchanged_functions=functions + ['layer'], scope='Byte-exact selection, dropped counts, placeholder priority, selected-image lookup and membership changes for identical candidate traversal. Equal priorities preserve the original heap behavior for that traversal. This does not establish equal traversal of the original global hash map and the C++ per-pane stores, metadata eligibility, native uploads, visual parity or performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'{len(frames)} frames and {sum(map(len, frames))} candidate placements match the original heap byte for byte')


if __name__ == '__main__':
    main()
