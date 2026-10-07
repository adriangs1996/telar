//! OSC 133 command-zone tracker for one PTY.

const std = @import("std");

pub const max_command_bytes = 64 * 1024;
pub const max_osc_bytes = 8 * 1024;

pub const Status = enum {
    completed,
    interrupted,
};

pub fn parseExitCode(options: []const u8) ?i32 {
    const first = options[0 .. std.mem.indexOfScalar(u8, options, ';') orelse options.len];
    if (first.len == 0) {
        return null;
    }
    return std.fmt.parseInt(i32, first, 10) catch null;
}

pub fn percentDecode(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var destination: usize = 0;
    while (source < input.len) {
        if (destination == output.len) {
            return null;
        }
        if (input[source] == '%') {
            if (source + 2 >= input.len) {
                return null;
            }
            const high = std.fmt.charToDigit(input[source + 1], 16) catch return null;
            const low = std.fmt.charToDigit(input[source + 2], 16) catch return null;
            output[destination] = @intCast(high * 16 + low);
            source += 3;
        } else {
            output[destination] = input[source];
            source += 1;
        }
        destination += 1;
    }
    return destination;
}
