//! Cohesive pane launch transaction.
//!
//! Allocation, proxy registration, process creation, store insertion, and
//! actor scheduling either establish a fully observable pane or execute the
//! matching rollback path.

const std = @import("std");
const max_argument_count_module = @import("telar-core").max_argument_count;
const command_support = @import("../../pty/command_support.zig");
const PaneOverrides = @import("PaneOverrides.zig");
const proxy_mod = @import("../../proxy/proxy_namespace.zig");
const Pane = @import("../../pane/Pane.zig");
const OutputCompletion = @import("../entrypoints/events/pane/OutputCompletion.zig");
const mark_module = @import("telar-core").mark;
const ExitCompletion = @import("../entrypoints/events/pane/ExitCompletion.zig");
const pane_module = @import("telar-core").pane;

comptime {
    std.debug.assert(max_argument_count_module <= command_support.max_args);
}

comptime {
    std.debug.assert(PaneOverrides.count <= proxy_mod.max_pane_overrides);
}

pub fn readPane(io: std.Io, pane: *Pane) OutputCompletion {
    const len = pane.session.read(io, &pane.output_buffer) catch |err|
        return .{ .pane = pane.key(), .result = err };
    mark_module(io, .pty_read);
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

pub fn waitPane(pane: *Pane) ExitCompletion {
    return .{ .pane = pane.key(), .result = pane.session.wait() };
}

test "pane overrides name the runtime socket and the pane's own identity" {
    var overrides: PaneOverrides = .{};

    const entries = overrides.build(.{
        .key = .{ .id = try pane_module(12), .generation = 3 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(4) },
            .tab_id = @enumFromInt(9),
        },
        .socket_path = "/tmp/telar.sock",
        .executable_path = "/opt/telar/bin/telar",
    });

    try std.testing.expectEqual(@as(usize, 6), entries.len);
    try std.testing.expectEqualStrings("TELAR_SOCKET_PATH", entries[0].name);
    try std.testing.expectEqualStrings("/tmp/telar.sock", entries[0].value);
    try std.testing.expectEqualStrings("TELAR_PANE_ID", entries[1].name);
    try std.testing.expectEqualStrings("12", entries[1].value);
    try std.testing.expectEqualStrings("TELAR_PANE_GENERATION", entries[2].name);
    try std.testing.expectEqualStrings("3", entries[2].value);
    try std.testing.expectEqualStrings("TELAR_WORKSPACE_ID", entries[3].name);
    try std.testing.expectEqualStrings("4", entries[3].value);
    try std.testing.expectEqualStrings("TELAR_TAB_ID", entries[4].name);
    try std.testing.expectEqualStrings("9", entries[4].value);
    try std.testing.expectEqualStrings("TELAR_BIN_PATH", entries[5].name);
    try std.testing.expectEqualStrings("/opt/telar/bin/telar", entries[5].value);
}
