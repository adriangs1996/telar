const std = @import("std");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const ClientRoute = @import("ClientRoute.zig");
const actions = @import("client_actions.zig");
const ClientCommand = @This();

pub const capacity = 4096;
request_id: id.RequestId,
route: ClientRoute,
action: actions.Action,
status: actions.Status = .request,
target_id: u64 = 0,
value: i64 = 0,
length: u16 = 0,
bytes: [capacity]u8 = @splat(0),

/// Owns deferred command text. Example: `try command.setText("query");`
pub fn setText(self: *ClientCommand, value: []const u8) !void {
    if (value.len > capacity or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidClientCommandText;
    }

    @memcpy(self.bytes[0..value.len], value);
    self.length = @intCast(value.len);
}

/// Borrows occupied text. Example: `try writer.writeAll(command.text());`
pub fn text(self: *const ClientCommand) []const u8 {
    return self.bytes[0..self.length];
}

/// Validates bounds before routing. Example: `try command.validateWire();`
pub fn validateWire(self: *const ClientCommand) !void {
    try codec.validateRequestId(self.request_id);
    try self.route.validateWire();
    if (self.length > capacity or !std.unicode.utf8ValidateSlice(self.text())) {
        return error.InvalidClientCommandText;
    }
}
