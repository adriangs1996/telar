const WorkspaceCreated = @This();
const source_namespace = @import("events.zig");
location: source_namespace.schema.TabLocation,
name: source_namespace.OwnedCreatedWorkspaceName,

/// Creates a committed workspace event that owns its canonical name.
///
/// ```zig
/// const event = try WorkspaceCreated.init(location, "backend");
/// ```
pub fn init(location: source_namespace.schema.TabLocation, name: []const u8) !WorkspaceCreated {
    return .{ .location = location, .name = try .init(name) };
}

/// Returns the event-owned canonical workspace name.
///
/// ```zig
/// const name = event.nameSlice();
/// ```
pub fn nameSlice(event: *const WorkspaceCreated) []const u8 {
    return event.name.slice();
}
