//! One lazy GUI allocation bounds long-span measurements and visible paint plans.
const std = @import("std");
const Key = @import("MessageLayoutKey.zig");
const Result = @import("MessageLayoutResult.zig");
const Plan = @import("MessageLayoutPlan.zig");
const Cache = @This();

pub const minimum_bytes = 1024;
pub const metric_capacity = 64;
pub const plan_capacity = 4;

metrics: [metric_capacity]?@import("MessageLayoutMetric.zig") = @splat(null),
plans: [plan_capacity]Plan = @splat(.{}),
next_metric: usize = 0,
next_plan: usize = 0,

/// Example: `if (cache.measurement(key)) |result| applyGeometry(result);`
pub fn measurement(cache: *const Cache, key: Key) ?Result {
    for (cache.metrics) |entry| {
        if (entry) |metric| {
            if (std.meta.eql(metric.key, key)) {
                return metric.result;
            }
        }
    }

    return null;
}

/// Example: `cache.remember(key, .{ .height = delta_y, .x = x });`
pub fn remember(cache: *Cache, key: Key, result: Result) void {
    for (&cache.metrics) |*entry| {
        if (entry.*) |metric| {
            if (std.meta.eql(metric.key, key)) {
                entry.* = .{ .key = key, .result = result };
                return;
            }
        }
    }

    cache.metrics[cache.next_metric] = .{ .key = key, .result = result };
    cache.next_metric = (cache.next_metric + 1) % metric_capacity;
}

/// Example: `if (cache.plan(key)) |plan| try replay(plan);`
pub fn plan(cache: *const Cache, key: Key) ?*const Plan {
    for (&cache.plans) |*entry| {
        if (entry.valid and std.meta.eql(entry.key, key)) {
            return entry;
        }
    }

    return null;
}

/// Reserves one replaceable plan during the synchronous preparation phase.
/// Example: `const plan = cache.begin(key);`
pub fn begin(cache: *Cache, key: Key) *Plan {
    const entry = &cache.plans[cache.next_plan];
    cache.next_plan = (cache.next_plan + 1) % plan_capacity;
    entry.key = key;
    entry.len = 0;
    entry.valid = false;
    entry.overflow = false;
    return entry;
}

test "message layout cache retains only bounded geometry and never partial plans" {
    try std.testing.expect(@sizeOf(Cache) < 180 * 1024);
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    const key: Key = .{ .text_hash = 1, .text_len = 2048, .owner = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .pane_generation = 1, .snapshot_revision = 1, .item_identity = 1, .section = .body, .source_offset = 0 }, .font_identity = 1, .font_revision = 0, .width = 400, .start_x = 0, .row = 25, .scale = 1, .pixel_height = 15, .cell_width = 9, .cell_height = 22, .face = .sans, .bold = false, .italic = false };
    const entry = cache.begin(key);
    for (0..Plan.capacity + 1) |_| {
        entry.append(.{ .offset = 0, .len = 1, .x = 0, .y = 0, .advance = 1 });
    }

    entry.complete(.{ .height = 40, .x = 2 });
    try std.testing.expect(cache.plan(key) == null);
    try std.testing.expectEqual(Plan.capacity, entry.len);
    cache.remember(key, .{ .height = 40, .x = 2 });
    try std.testing.expectEqual(@as(f32, 40), cache.measurement(key).?.height);
    var changed = key;
    changed.font_revision += 1;
    try std.testing.expect(cache.measurement(changed) == null);
}
