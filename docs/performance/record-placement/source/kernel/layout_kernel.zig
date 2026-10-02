//! Synthetic kernel: N records the size of telar's runtime `Pane`, visited
//! once per "flush" reading the same hot fields, under five placements.
//! It isolates what placement (an allocator's decision) and representation
//! (the type's decision) each contribute. Not telar code.
const std = @import("std");
const offsets_file = @import("offsets.zig");

const page = 16 * 1024;
const record_bytes = offsets_file.record_bytes;
const hot_offsets = offsets_file.hot_offsets;
const group_offset = offsets_file.group_offset;
const max_records = 256;
const color_stride = 512;
const colors = page / color_stride;
const evict_bytes = 512 * 1024;

const Variant = enum { aligned, colored, packed_records, grouped, grouped_colored, dense };
const variants = [_]Variant{ .aligned, .colored, .packed_records, .grouped, .grouped_colored, .dense };

const Layout = struct {
    items: [max_records]?[*]u8 = @splat(null),
    offsets: [hot_offsets.len]usize = hot_offsets,
    columns: [hot_offsets.len][max_records]u64 = undefined,
    count: usize = 0,
    dense: bool = false,
};

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
const clock_uptime_raw = 8;

fn nowNs() u64 {
    return clock_gettime_nsec_np(clock_uptime_raw);
}

fn reserve(bytes: usize) [*]u8 {
    return std.heap.page_allocator.rawAlloc(bytes, .fromByteUnits(page), @returnAddress()).?;
}

fn build(layout: *Layout, variant: Variant, count: usize) void {
    const slot_bytes = std.mem.alignForward(usize, record_bytes, page) + page;
    const region = reserve(slot_bytes * count);
    layout.count = count;
    layout.dense = variant == .dense;
    layout.offsets = hot_offsets;
    if (variant == .grouped or variant == .grouped_colored) {
        for (&layout.offsets, 0..) |*offset, field| {
            offset.* = group_offset + field * 8;
        }
    }

    for (0..count) |index| {
        const base = switch (variant) {
            .aligned, .grouped, .dense => region + index * slot_bytes,
            .colored, .grouped_colored => region + index * slot_bytes + (index % colors) * color_stride,
            .packed_records => region + index * record_bytes,
        };
        layout.items[index] = base;
        for (layout.offsets, 0..) |offset, field| {
            const value: u64 = index * 31 + field;
            @as(*align(1) u64, @ptrCast(base + offset)).* = value;
            layout.columns[field][index] = value;
        }
    }
}

noinline fn flush(layout: *const Layout) u64 {
    var sum: u64 = 0;
    if (layout.dense) {
        for (0..layout.count) |index| {
            inline for (0..hot_offsets.len) |field| {
                sum +%= layout.columns[field][index];
            }
        }

        return sum;
    }

    for (&layout.items) |*slot| {
        const base = slot.* orelse continue;
        inline for (0..hot_offsets.len) |field| {
            sum +%= @as(*align(1) const u64, @ptrCast(base + layout.offsets[field])).*;
        }
    }

    return sum;
}

noinline fn evict(scratch: []u8) u64 {
    var sum: u64 = 0;
    var index: usize = 0;
    while (index < scratch.len) : (index += 64) {
        sum +%= scratch[index];
    }

    return sum;
}

fn launder(pointer: anytype) @TypeOf(pointer) {
    var value = pointer;
    std.mem.doNotOptimizeAway(&value);
    return value;
}

fn measure(layout: *const Layout, scratch: []u8, flushes: usize, evicting: bool) f64 {
    var checksum: u64 = 0;
    if (!evicting) {
        const start = nowNs();
        for (0..flushes) |_| {
            checksum +%= flush(launder(layout));
        }

        const total = nowNs() - start;
        std.mem.doNotOptimizeAway(checksum);
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(flushes));
    }

    // Only the flush is timed; the clock's own cost is measured the same
    // way around nothing and subtracted.
    var spent: u64 = 0;
    var clock: u64 = 0;
    for (0..flushes) |_| {
        checksum +%= evict(launder(scratch));
        const start = nowNs();
        checksum +%= flush(launder(layout));
        spent += nowNs() - start;

        checksum +%= evict(launder(scratch));
        const empty = nowNs();
        std.mem.doNotOptimizeAway(launder(layout));
        clock += nowNs() - empty;
    }

    std.mem.doNotOptimizeAway(checksum);
    const net = if (spent > clock) spent - clock else 0;
    return @as(f64, @floatFromInt(net)) / @as(f64, @floatFromInt(flushes));
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

pub fn main() !void {
    const rounds = 9;
    const scratch_ptr = reserve(evict_bytes);
    const scratch = scratch_ptr[0..evict_bytes];
    @memset(scratch, 1);

    const layouts = try std.heap.page_allocator.alloc(Layout, variants.len);
    std.debug.print("record_bytes={d} hot_fields={d}\n", .{ record_bytes, hot_offsets.len });
    std.debug.print("{s:>8} {s:>6} {s:>16} {s:>12} {s:>12}\n", .{ "records", "mode", "variant", "ns/flush", "ns/record" });

    layouts[0] = .{};
    var scan_samples: [rounds]f64 = undefined;
    for (&scan_samples) |*sample| {
        sample.* = measure(&layouts[0], scratch, 200_000, false);
    }

    std.debug.print("scan of {d} empty slots: {d:.1} ns\n", .{ max_records, median(&scan_samples) });

    for ([_]usize{ 4, 8, 12, 16, 32, 64, 256 }) |count| {
        for (variants, layouts) |variant, *layout| {
            layout.* = .{};
            build(layout, variant, count);
        }

        for ([_]bool{ false, true }) |evicting| {
            const flushes: usize = if (evicting) 20_000 else 200_000;
            var samples: [variants.len][rounds]f64 = undefined;
            for (0..rounds) |round| {
                for (0..variants.len) |step| {
                    const which = if (round % 2 == 0) step else variants.len - 1 - step;
                    _ = measure(&layouts[which], scratch, flushes / 10, evicting);
                    samples[which][round] = measure(&layouts[which], scratch, flushes, evicting);
                }
            }

            for (variants, 0..) |variant, which| {
                const value = median(&samples[which]);
                std.debug.print("{d:>8} {s:>6} {s:>16} {d:>12.1} {d:>12.2}\n", .{ count, if (evicting) "evict" else "warm", @tagName(variant), value, value / @as(f64, @floatFromInt(count)) });
            }
        }
    }
}
