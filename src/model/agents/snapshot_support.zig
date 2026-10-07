//! Bounded client replica of the runtime's currently open agents.
//!
//! The runtime owns agent truth. This capability owns one immutable client
//! copy so application decisions and presentation read the same revision.

const std = @import("std");

pub fn copyLabel(destination: []u8, source: []const u8) !u8 {
    if (source.len > destination.len) {
        return error.AgentLabelTooLong;
    }
    if (!std.unicode.utf8ValidateSlice(source)) {
        return error.InvalidAgentLabel;
    }

    for (source) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidAgentLabel;
        }
    }

    @memcpy(destination[0..source.len], source);
    return @intCast(source.len);
}
