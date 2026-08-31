//! Application use case for storing runtime-owned pane metadata.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const UpdatePaneMetadataHandler = struct {
    model: *client_model.Model,

    /// Stores one decoded metadata fact without touching view or composition
    /// resources. The presenter observes any published display revision.
    ///
    /// ```zig
    /// const commit = try handler.execute(command);
    /// ```
    pub fn execute(handler: *UpdatePaneMetadataHandler, command: client_model.PaneMetadataCommand) !?client_model.PaneMetadataCommit {
        return handler.model.updatePaneMetadata(command);
    }
};

test "UpdatePaneMetadataHandler stores cwd and foreground through the client model" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    var handler: UpdatePaneMetadataHandler = .{ .model = &model };

    const cwd = (try handler.execute(.{ .cwd = .{
        .pane_id = pane_id,
        .path = "/work/telar",
    } })).?;
    const foreground = (try handler.execute(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })).?;

    try std.testing.expectEqual(client_model.PaneMetadataKind.cwd, cwd.kind);
    try std.testing.expectEqual(client_model.PaneMetadataKind.foreground, foreground.kind);
    try std.testing.expectEqualStrings("/work/telar", model.workspace.findPane(pane_id).?.cwdSlice());
    try std.testing.expectEqualStrings("zsh", model.workspace.findPane(pane_id).?.foregroundName());
    try std.testing.expectEqual(client_model.Version{
        .pane_metadata = 2,
        .pane_foreground = 1,
    }, model.version());
}

test "UpdatePaneMetadataHandler ignores stale and repeated facts" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(1) },
        .tab_id = @enumFromInt(1),
    };
    const pane_id: schema.PaneId = @enumFromInt(1);
    try model.workspace.bootstrap(pane_id, location, .{ .cols = 2, .rows = 2 });
    var handler: UpdatePaneMetadataHandler = .{ .model = &model };
    _ = (try handler.execute(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })).?;
    const version = model.version();

    try std.testing.expect((try handler.execute(.{ .foreground = .{
        .pane_id = pane_id,
        .name = "zsh",
    } })) == null);
    try std.testing.expect((try handler.execute(.{ .cwd = .{
        .pane_id = @enumFromInt(9),
        .path = "/missing",
    } })) == null);
    try std.testing.expectEqualDeep(version, model.version());
}
