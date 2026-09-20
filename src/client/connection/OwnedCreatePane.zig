//! Owns queued pane argv in the outbox slot's existing byte storage.
const core = @import("telar-core");
const OwnedArguments = @import("OwnedArguments.zig");
const Self = @This();

request_id: core.RequestId,
location: core.TabLocation,
size: core.TerminalSize,
launch: core.Launch,
arguments: OwnedArguments = .{},

/// Copies transient argv before the input handler returns.
/// Example: `try pending.ownArguments(slot_bytes);`
pub fn ownArguments(self: *Self, bytes: []u8) !void {
    if (self.launch.arguments.len == 0) {
        return error.InvalidArgumentCount;
    }

    self.arguments = try OwnedArguments.copy(self.launch.arguments, bytes);
    self.launch.arguments = &.{};
}

/// Borrows owned argv only for synchronous wire encoding.
/// Example: `const request = pending.view(slot_bytes, &scratch);`
pub fn view(self: *const Self, bytes: []const u8, scratch: *[core.max_argument_count][]const u8) core.CreatePane {
    var launch = self.launch;
    launch.arguments = self.arguments.view(bytes, scratch);
    return .{ .request_id = self.request_id, .location = self.location, .size = self.size, .launch = launch };
}
