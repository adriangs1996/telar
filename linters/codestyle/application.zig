const std = @import("std");
const ConfigType = @import("Config.zig");
const paths = @import("paths.zig");
const ReporterType = @import("Reporter.zig");
const SourceFileType = @import("SourceFile.zig");
const fixer_support = @import("fixes.zig");
const analyzer_support = @import("analysis.zig");

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

const Processor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fix: bool,
    reporter: *ReporterType,

    /// Checks one file, optionally applying safe formatting fixes first.
    /// Example: `try processor.process("src/client/panes/Pane.zig");`.
    pub fn process(self: Processor, path: []const u8) !void {
        var file = try SourceFileType.open(self.allocator, self.io, path);
        defer file.deinit();

        if (self.fix) {
            const result = try fixer_support.fixSource(self.allocator, file.source);

            if (result) |fixed| {
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
        const violations = try analyzer_support.lintFile(self.allocator, source, path);
        defer self.allocator.free(violations);

        try self.reporter.report(path, violations);
    }
};
