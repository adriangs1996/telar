const std = @import("std");
const command = @import("command.zig");

pub fn main(init: std.process.Init) !void {
    std.process.exit(try command.run(init));
}
