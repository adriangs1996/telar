//! Pane command grammar and validated options.

const PaneDirectionType = @import("telar-core").PaneDirection;
const std = @import("std");

pub const PaneAction = enum { read, send_keys, focus };

pub fn parsePaneDirection(value: []const u8) ?PaneDirectionType {
    if (std.mem.eql(u8, value, "left")) {
        return .left;
    }

    if (std.mem.eql(u8, value, "right")) {
        return .right;
    }

    if (std.mem.eql(u8, value, "up")) {
        return .up;
    }

    if (std.mem.eql(u8, value, "down")) {
        return .down;
    }

    return null;
}
