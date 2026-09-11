const WorkspaceRenamed = @This();
const source_namespace = @import("events.zig");
location: source_namespace.schema.WorkspaceLocation,
name: source_namespace.OwnedExplicitWorkspaceName,

/// Validates and owns the canonical name of a renamed workspace.
///
/// ```zig
/// const event = try WorkspaceRenamed.init(location, "backend");
/// ```
pub fn init(location: source_namespace.schema.WorkspaceLocation, name: []const u8) !WorkspaceRenamed {
    return .{ .location = location, .name = try .init(name) };
}

/// Returns the event-owned canonical workspace name.
///
/// ```zig
/// const name = event.nameSlice();
/// ```
pub fn nameSlice(event: *const WorkspaceRenamed) []const u8 {
    return event.name.slice();
}
