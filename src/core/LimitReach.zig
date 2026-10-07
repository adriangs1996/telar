//! One time a limit was reached: the limit and, when the caller knows it,
//! how much was asked for. It is what a flow hands to `limit_reached.report`.
const std = @import("std");
const Limit = @import("Limit.zig");
const LimitReach = @This();

/// The longest text `describe` writes: a full name, a full noun and three
/// 20-digit numbers with their separators.
pub const max_description_bytes = Limit.max_name_bytes + Limit.max_noun_bytes + 96;
/// Bytes of the longest route a report may carry.
pub const max_route_bytes = 32;

limit: Limit,
/// What the caller tried to fit, in the limit's unit; null when unknown.
requested: ?u64 = null,
/// The safety net that caught the reach (`window_draw`, `agent_tick`), or
/// empty when the flow that enforces the limit reported it.
route: []const u8 = "",

/// Checks a reach another process sent: its limit and a route of letters,
/// digits and `_`.
///
/// ```zig
/// try reach.validate();
/// ```
pub fn validate(self: LimitReach) !void {
    try self.limit.validate();
    if (self.route.len > max_route_bytes) {
        return error.InvalidLimitRoute;
    }

    for (self.route) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
            return error.InvalidLimitRoute;
        }
    }
}

/// Writes the one-line text every surface shows for this reach, with how
/// many times it happened when that is more than once.
///
/// ```zig
/// var buffer: [LimitReach.max_description_bytes]u8 = undefined;
/// const text = reach.describe(&buffer, 3); // "bars.max_bar_actions: 17 click actions; limit 4 (3 times)"
/// ```
pub fn describe(self: LimitReach, buffer: *[max_description_bytes]u8, hits: u64) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    self.write(&writer, hits) catch {};

    return writer.buffered();
}

fn write(self: LimitReach, writer: *std.Io.Writer, hits: u64) !void {
    const separator = if (self.limit.noun.len == 0) "" else " ";
    try writer.print("{s}: ", .{self.limit.name});

    if (self.requested) |requested| {
        try writer.print("{d}{s}{s}; limit {d}", .{ requested, separator, self.limit.noun, self.limit.value });
    } else if (self.limit.value == 0) {
        // An unnamed limit (`limit_reached.unnamed`) knows only its error.
        try writer.writeAll("limit reached");
    } else {
        try writer.print("limit {d}{s}{s} reached", .{ self.limit.value, separator, self.limit.noun });
    }

    if (hits > 1) {
        try writer.print(" ({d} times)", .{hits});
    }
}
