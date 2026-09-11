//! Authoritative semantic state owned by one running Telar runtime.
//!
//! Workspace data is passive and accessed through its repository. `PaneStore`
//! and `Tracker` remain transitional capability roots until their semantic
//! state is separated from live resources and observation behavior.

const GraphicsLimitsType = @import("../../media/GraphicsLimits.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const std = @import("std");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const RepositoryType = @import("../../workspace/Repository.zig");

test "runtime model starts with empty configured capability roots" {
    const graphics_limits: GraphicsLimitsType = .{
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), model.agents.snapshot(&entries).len);
}

test "workspace repository releases allocations retained by the runtime model" {
    var model: RuntimeModel = .{ .panes = .{} };
    defer model.panes.deinit();
    var repository = RepositoryType.init(&model.workspaces, std.testing.allocator);
    defer repository.deinit();

    _ = try repository.ensure("/tmp/telar-model-test");

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
