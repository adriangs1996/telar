const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const events = @import("events.zig");
const WorkspaceRenamed = @This();

location: WorkspaceLocationType,
name: events.OwnedExplicitWorkspaceName,

/// Validates and owns the canonical name of a renamed workspace.
///
/// ```zig
/// const event = try WorkspaceRenamed.init(location, "backend");
/// ```
pub fn init(location: WorkspaceLocationType, name: []const u8) !WorkspaceRenamed {
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
