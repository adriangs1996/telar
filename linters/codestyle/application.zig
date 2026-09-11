const std = @import("std");
const arguments = @import("arguments.zig");
const codestyle = @import("root.zig");
const paths = @import("paths.zig");
const reporter_module = @import("reporter_support.zig");
const source_file = @import("source_file.zig");

pub const Io = std.Io;

const Processor = @import("Processor.zig");

/// Runs codestyle over the configured source roots and returns its process status.
///
/// ```zig
/// const status = try run(init, config, writer);
/// ```
pub fn run(init: std.process.Init, config: arguments.Config, writer: *Io.Writer) !u8 {
    const files = try paths.collect(init.gpa, init.io, config.paths);
    defer paths.free(init.gpa, files);

    var reporter: reporter_module.Reporter = .{ .writer = writer };
    const processor: Processor = .{
        .allocator = init.gpa,
        .io = init.io,
        .fix = config.fix,
        .reporter = &reporter,
    };

    for (files) |path| {
        try processor.process(path);
    }

    try reporter.finish();
    return reporter.exitCode();
}
