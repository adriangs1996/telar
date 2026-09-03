const std = @import("std");
const arguments = @import("arguments.zig");
const codestyle = @import("root.zig");
const paths = @import("paths.zig");
const reporter_module = @import("reporter.zig");
const source_file = @import("source_file.zig");

const Io = std.Io;

const Processor = struct {
    allocator: std.mem.Allocator,
    io: Io,
    fix: bool,
    reporter: *reporter_module.Reporter,

    fn process(self: Processor, path: []const u8) !void {
        var file = try source_file.SourceFile.open(self.allocator, self.io, path);
        defer file.deinit();

        if (self.fix) {
            if (try codestyle.fixSource(self.allocator, file.source)) |fixed| {
                defer self.allocator.free(fixed);

                try file.replace(self.io, fixed);
                self.reporter.recordFixed();
                try self.analyze(path, fixed);
                return;
            }
        }

        try self.analyze(path, file.source);
    }

    fn analyze(self: Processor, path: []const u8, source: [:0]const u8) !void {
        const violations = try codestyle.lintSource(self.allocator, source);
        defer self.allocator.free(violations);

        try self.reporter.report(path, violations);
    }
};

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
