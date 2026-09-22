const core = @import("telar-core");
const events = @import("events.zig");
const WorkspaceCreated = @This();

location: core.TabLocation,
name: events.OwnedCreatedWorkspaceName,

/// Creates a committed workspace event that owns its canonical name.
///
/// ```zig
/// const event = try WorkspaceCreated.init(location, "backend");
/// ```
pub fn init(location: core.TabLocation, name: []const u8) !WorkspaceCreated {
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
