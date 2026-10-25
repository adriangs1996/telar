const std = @import("std");
const core = @import("telar-core");
const Store = @import("history/persistence/Store.zig");
const LaunchAttempt = @import("history/LaunchAttempt.zig");

export fn record_launch_failure(path: [*:0]const u8, seed: u32) c_int {
    persist(std.mem.span(path), seed) catch return 1;
    return 0;
}

fn persist(path: [:0]const u8, seed: u32) !void {
    var store = try Store.open(path);
    defer store.close();

    const identities = [_]u64{ 0, 17, std.math.maxInt(i64) };
    const texts = [_][]const u8{ "", "spaces and café 好", "embedded\x00text", "OutOfMemory" };
    const identity = identities[seed % identities.len];
    const value: LaunchAttempt = .{
        .pane_id = @enumFromInt(identity),
        .pane_generation = seed + 1,
        .location = .{
            .workspace = if (seed % 2 == 0) .{ .workspace = @enumFromInt(identity) } else .{ .worktree = @enumFromInt(identity) },
            .tab_id = @enumFromInt(identity),
        },
        .started_at_ms = @as(i64, seed) - 50,
        .failed_at_ms = @as(i64, seed) + 100,
        .phase = @enumFromInt(seed % 3),
        .workspace_path = @constCast(texts[seed % texts.len]),
        .shell = @constCast(texts[(seed + 1) % texts.len]),
        .cause = @constCast(texts[(seed + 2) % texts.len]),
    };
    try store.insertLaunchAttempt(&value);
}
