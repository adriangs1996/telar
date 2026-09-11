//! Cohesive pane launch transaction.
//!
//! Allocation, proxy registration, process creation, store insertion, and
//! actor scheduling either establish a fully observable pane or execute the
//! matching rollback path.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const pane_exit_coordinator = @import("../entrypoints/events/pane/exit.zig");
const pane_output_pipeline = @import("../entrypoints/events/pane/output.zig");
const proxy_mod = @import("../../proxy/root.zig");
const pty = @import("../../pty/root.zig");

pub const Io = std.Io;
pub const Pane = pane_mod.Pane;
pub const PaneStore = pane_mod.PaneStore;
pub const schema = core.schema;

comptime {
    std.debug.assert(schema.max_argument_count <= pty.max_args);
}

pub const PaneOutputEvent = pane_output_pipeline.Completion;

pub const PaneExitEvent = pane_exit_coordinator.Completion;

pub const LaunchRequest = @import("LaunchRequest.zig");

pub const PaneIdentity = @import("PaneIdentity.zig");

pub const PaneOverrides = @import("PaneOverrides.zig");

comptime {
    std.debug.assert(PaneOverrides.count <= proxy_mod.max_pane_overrides);
}

const LaunchFailure = @import("LaunchFailure.zig");

const CommandInitialization = @import("CommandInitialization.zig");

pub const LaunchTestFault = @import("LaunchTestFault.zig");

pub const PaneLauncher = @import("GenericPaneLauncher.zig").Type;

const OwnedCommand = @import("OwnedCommand.zig");

pub fn readPane(io: Io, pane: *Pane) PaneOutputEvent {
    const len = pane.session.read(io, &pane.output_buffer) catch |err|
        return .{ .pane = pane.key(), .result = err };
    core.echo_trace.mark(io, .pty_read);
    return .{ .pane = pane.key(), .result = @intCast(len) };
}

pub fn waitPane(pane: *Pane) PaneExitEvent {
    return .{ .pane = pane.key(), .result = pane.session.wait() };
}

test "pane overrides name the runtime socket and the pane's own identity" {
    var overrides: PaneOverrides = .{};

    const entries = overrides.build(.{
        .key = .{ .id = try schema.id.pane(12), .generation = 3 },
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
