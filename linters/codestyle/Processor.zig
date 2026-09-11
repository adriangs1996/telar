const std = @import("std");
const ReporterType = @import("Reporter.zig");
const SourceFileType = @import("SourceFile.zig");
const fixer_support = @import("fixes.zig");
const analyzer_support = @import("analysis.zig");
const Processor = @This();

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
