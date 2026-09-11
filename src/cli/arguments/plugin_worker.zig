//! plugin-worker command grammar.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;

pub const PluginWorkerOptions = @import("PluginWorkerOptions.zig");

pub fn parseWorkerBool(value: [*:0]const u8) !bool {
    const text = std.mem.span(value);
    if (std.mem.eql(u8, text, "0")) {
        return false;
    }
    if (std.mem.eql(u8, text, "1")) {
        return true;
    }

    return error.InvalidPluginWorkerArguments;
}
