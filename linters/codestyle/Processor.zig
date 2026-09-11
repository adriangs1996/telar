const Processor = @This();
const std = @import("std");
const source_namespace = @import("application.zig");
const reporter_module = @import("reporter_support.zig");
const source_file = @import("source_file.zig");
const codestyle = @import("root.zig");
allocator: std.mem.Allocator,
io: source_namespace.Io,
fix: bool,
reporter: *reporter_module.Reporter,

fn process(self: Processor, path: []const u8) !void {
    var file = try source_file.SourceFile.open(self.allocator, self.io, path);
    defer file.deinit();

    if (self.fix) {
        const result = try codestyle.fixSource(self.allocator, file.source);

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
    const violations = try codestyle.lintSource(self.allocator, source);
    defer self.allocator.free(violations);

    try self.reporter.report(path, violations);
}
