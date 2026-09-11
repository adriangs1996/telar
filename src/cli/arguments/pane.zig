//! Pane command grammar and validated options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;
const values = @import("values.zig");
pub const Target = values.Target;
const max_wait_timeout_seconds = values.max_wait_timeout_seconds;
const default_wait_timeout_seconds = values.default_wait_timeout_seconds;
const HookAgent = values.HookAgent;
const parseHookAgent = values.parseHookAgent;
const parseWaitStatus = values.parseWaitStatus;
const parseTimeoutSeconds = values.parseTimeoutSeconds;
pub const parseLineCount = values.parseLineCount;
pub const parseTextSource = values.parseTextSource;

pub const PaneAction = enum { read, send_keys, focus };

pub const PaneOptions = @import("PaneOptions.zig");

pub fn parsePaneDirection(value: []const u8) ?core.schema.PaneDirection {
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
