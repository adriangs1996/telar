//! Passive semantic state owned by one disposable client.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");

const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Version = struct {
    generation: u64 = 0,
};

pub const Change = enum {
    unchanged,
    changed,
};

pub const Model = struct {
    workspace: tabs_mod.Model,
    generation: u64 = 0,

    /// Creates the semantic model with the configured pane appearance.
    ///
    /// ```zig
    /// var model = Model.init(gpa, true);
    /// ```
    pub fn init(gpa: std.mem.Allocator, pane_gaps: bool) Model {
        var workspace = tabs_mod.Model.init(gpa);
        workspace.setPaneGaps(pane_gaps);

        return .{ .workspace = workspace };
    }

    /// Releases all semantic workspace state owned by the model.
    ///
    /// ```zig
    /// defer model.deinit();
    /// ```
    pub fn deinit(model: *Model) void {
        model.workspace.deinit();
    }

    /// Returns the version that presenters use to observe committed changes.
    ///
    /// ```zig
    /// const before = model.version();
    /// ```
    pub fn version(model: *const Model) Version {
        return .{ .generation = model.generation };
    }

    /// Returns the active tab identity without exposing workspace storage.
    ///
    /// ```zig
    /// const location = model.activeTabLocation() orelse return;
    /// ```
    pub fn activeTabLocation(model: *const Model) ?schema.TabLocation {
        const active = model.workspace.activeConst() orelse return null;

        return active.location;
    }

    /// Commits a runtime-confirmed tab position and advances the model once.
    ///
    /// ```zig
    /// const change = try model.applyTabPosition(location, position);
    /// ```
    pub fn applyTabPosition(model: *Model, location: schema.TabLocation, position: u16) !Change {
        const current_workspace = model.workspace.workspace orelse return error.UnexpectedWorkspace;
        if (!std.meta.eql(current_workspace, location.workspace)) {
            return error.UnexpectedWorkspace;
        }

        const change = try model.workspace.applyPosition(location.tab_id, position);
        if (change == .unchanged) {
            return .unchanged;
        }

        model.generation +%= 1;
        return .changed;
    }
};

test "tab position commits version semantic changes only" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const first: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    const second: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(2),
    };
    try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
    _ = try model.workspace.addCreated(.{
        .request_id = @enumFromInt(2),
        .location = second,
        .position = 1,
        .label = "logs",
        .root_pane_id = @enumFromInt(2),
    }, .{ .cols = 20, .rows = 5 });
    try std.testing.expect(model.workspace.select(first.tab_id));

    try std.testing.expectEqual(Change.changed, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().generation);
    try std.testing.expectEqual(first, model.activeTabLocation().?);

    try std.testing.expectEqual(Change.unchanged, try model.applyTabPosition(first, 1));
    try std.testing.expectEqual(@as(u64, 1), model.version().generation);
}

test "rejected tab positions do not advance the model" {
    var model = Model.init(std.testing.allocator, true);
    defer model.deinit();

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
    const location: schema.TabLocation = .{
        .workspace = workspace,
        .tab_id = @enumFromInt(1),
    };
    try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });

    const other_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(error.UnexpectedWorkspace, model.applyTabPosition(other_workspace, 0));
    try std.testing.expectError(error.TabNotFound, model.applyTabPosition(.{
        .workspace = workspace,
        .tab_id = @enumFromInt(9),
    }, 0));
    try std.testing.expectError(error.InvalidTabPosition, model.applyTabPosition(location, 1));
    try std.testing.expectEqual(@as(u64, 0), model.version().generation);
}
