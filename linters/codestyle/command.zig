const std = @import("std");
const application = @import("application.zig");
const arguments = @import("arguments.zig");

const Io = std.Io;

/// Parses process arguments, owns stderr buffering, and dispatches the command.
///
/// ```zig
/// const status = try run(init);
/// ```
pub fn run(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = try arguments.parse(init.arena.allocator(), argv);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buffer);
    const writer = &stderr_writer.interface;

    switch (parsed) {
        .config => |config| return application.run(init, config, writer),
        .unknown_option => |option| {
            try writer.print("codestyle: unknown option: {s}\n", .{option});
            try writer.flush();
            return 2;
        },
    }
}
