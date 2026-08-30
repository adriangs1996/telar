//! Authoritative semantic state owned by one running Telar runtime.
//!
//! Workspace data is passive and accessed through its repository. `PaneStore`
//! and `Tracker` remain transitional capability roots until their semantic
//! state is separated from live resources and observation behavior.

const std = @import("std");
const core = @import("telar-core");
const agent = @import("../../agent/root.zig");
const pane = @import("../../pane/root.zig");
const workspace = @import("../../workspace/root.zig");

pub const RuntimeModel = struct {
    workspaces: workspace.State = .{},
    panes: pane.PaneStore,
    agents: agent.Tracker = .{},
};

test "runtime model starts with empty configured capability roots" {
    const graphics_limits: pane.GraphicsLimits = .{
        .pane_bytes = 1024,
        .global_bytes = 4096,
        .images_per_pane = 2,
        .placements_per_pane = 2,
        .payload_bytes = 256,
        .chunks_per_image = 4,
    };
    var model: RuntimeModel = .{
        .panes = .{
            .graphics_limits = graphics_limits,
            .graphics_budget = .init(graphics_limits.global_bytes),
        },
    };
    defer model.panes.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.workspaces.count);
    try std.testing.expectEqual(@as(usize, 0), model.panes.count);
    try std.testing.expectEqual(graphics_limits.global_bytes, model.panes.graphics_budget.limit);
    try std.testing.expectEqualDeep(graphics_limits, model.panes.graphics_limits);

    var entries: [agent.max_records]core.schema.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), model.agents.snapshot(&entries).len);
}

test "workspace repository releases allocations retained by the runtime model" {
    var model: RuntimeModel = .{ .panes = .{} };
    defer model.panes.deinit();
    var repository = workspace.Repository.init(&model.workspaces, std.testing.allocator);
    defer repository.deinit();

    _ = try repository.ensure("/tmp/telar-model-test");

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
