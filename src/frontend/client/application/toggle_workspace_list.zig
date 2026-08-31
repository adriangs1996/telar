//! Application use case for toggling the top-bar workspace list.

const std = @import("std");
const client_model = @import("../model.zig");

pub const ToggleWorkspaceListHandler = struct {
    model: *client_model.Model,

    /// Commits the workspace-list preference without deciding when or how
    /// its view projection is rendered.
    ///
    /// ```zig
    /// const change = handler.execute();
    /// ```
    pub fn execute(handler: *ToggleWorkspaceListHandler) client_model.WorkspaceListCollapse {
        return handler.model.toggleWorkspaceList();
    }
};

test "ToggleWorkspaceListHandler changes only committed client state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var handler: ToggleWorkspaceListHandler = .{ .model = &model };

    const collapsed = handler.execute();

    try std.testing.expect(collapsed.collapsed);
    try std.testing.expect(model.workspaceListCollapsed());
    try std.testing.expectEqual(client_model.Version{ .chrome = 1 }, model.version());

    const expanded = handler.execute();

    try std.testing.expect(!expanded.collapsed);
    try std.testing.expect(!model.workspaceListCollapsed());
    try std.testing.expectEqual(client_model.Version{ .chrome = 2 }, model.version());
}
