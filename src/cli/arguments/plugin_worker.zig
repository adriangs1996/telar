//! plugin-worker command grammar.

const std = @import("std");

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
