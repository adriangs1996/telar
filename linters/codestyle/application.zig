const std = @import("std");
const ConfigType = @import("Config.zig");
const paths = @import("paths.zig");
const ReporterType = @import("Reporter.zig");
const Processor = @import("Processor.zig");

/// Runs codestyle over the configured source roots and returns its process status.
///
/// ```zig
/// const status = try run(init, config, writer);
/// ```
pub fn run(init: std.process.Init, config: ConfigType, writer: *std.Io.Writer) !u8 {
    const files = try paths.collect(init.gpa, init.io, config.paths);
    defer paths.free(init.gpa, files);

    var reporter: ReporterType = .{ .writer = writer };
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
