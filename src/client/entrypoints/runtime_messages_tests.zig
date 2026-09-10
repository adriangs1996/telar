const std = @import("std");
const schema = @import("telar-core").schema;
const dispatch = @import("root.zig").runtime_messages.dispatch;

const Outcome = enum { applied, ignored, exit };
const Capture = struct {
    calls: usize = 0,
    outcome: Outcome = .applied,
    history_failure: bool = false,
};

const Adapter = struct {
    pub fn apply(capture: *Capture, _: anytype) !Outcome {
        capture.calls += 1;
        return capture.outcome;
    }

    pub fn failed(capture: *Capture, _: anytype) bool {
        return capture.history_failure;
    }

    pub fn output(capture: *Capture, _: anytype) Outcome {
        capture.calls += 1;
        return capture.outcome;
    }

    pub const applyCwd = apply;
    pub const applyForeground = apply;
    pub const applyTitle = apply;
    pub const applyExit = apply;
    pub const applyRuntime = apply;
    pub const applyDeliveryReport = apply;
    pub const matches = apply;
    pub const pruned = apply;
};

const VoidAdapter = struct {
    pub fn apply(capture: *Capture, _: anytype) !void {
        capture.calls += 1;
    }
};

const Adapters = struct {
    pub const agent_sounds = Adapter;
    pub const agent_snapshots = Adapter;
    pub const notifications = Adapter;
    pub const client_layouts = VoidAdapter;
    pub const pane_clipboards = VoidAdapter;
    pub const pane_closures = Adapter;
    pub const pane_frames = Adapter;
    pub const pane_focus_commands = VoidAdapter;
    pub const pane_graphics = Adapter;
    pub const pane_metadata = Adapter;
    pub const pane_openings = Adapter;
    pub const pane_progress = Adapter;
    pub const copy_modes = Adapter;
    pub const history_palettes = Adapter;
    pub const suggestions = Adapter;
    pub const proxy_status = Adapter;
    pub const request_failures = Adapter;
    pub const resync_requirements = Adapter;
    pub const system_metrics = Adapter;
    pub const tab_closures = Adapter;
    pub const tab_creations = Adapter;
    pub const tab_moves = Adapter;
    pub const tab_renames = Adapter;
    pub const tab_snapshots = Adapter;
    pub const workspace_lists = Adapter;
    pub const workspace_snapshots = VoidAdapter;
};

test "runtime stopping exits without calling slice adapters" {
    var capture: Capture = .{};
    try std.testing.expectEqual(@as(?u8, 0), try dispatch(&capture, .runtime_stopping, Adapters));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "decoded metadata is synchronously delivered without initializing a host" {
    var capture: Capture = .{};
    const message: schema.ServerMessage = .{ .pane_title = .{
        .pane_id = @enumFromInt(1),
        .title = "headless",
    } };
    try std.testing.expect((try dispatch(&capture, message, Adapters)) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
