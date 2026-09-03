const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const Io = std.Io;

pub const Reporter = struct {
    writer: *Io.Writer,
    violation_count: usize = 0,
    fixed_file_count: usize = 0,

    /// Writes compiler-compatible diagnostics for one source file.
    ///
    /// ```zig
    /// try reporter.report("src/main.zig", violations);
    /// ```
    pub fn report(self: *Reporter, path: []const u8, violations: []const diagnostic.Violation) !void {
        for (violations) |violation| {
            try self.writeViolation(path, violation);
            self.violation_count += 1;
        }
    }

    /// Records one file replaced by autofix.
    ///
    /// ```zig
    /// reporter.recordFixed();
    /// ```
    pub fn recordFixed(self: *Reporter) void {
        self.fixed_file_count += 1;
    }

    /// Flushes diagnostics and prints the autofix summary when files changed.
    ///
    /// ```zig
    /// try reporter.finish();
    /// ```
    pub fn finish(self: *Reporter) !void {
        if (self.fixed_file_count != 0) {
            try self.writer.print("codestyle: fixed {d} file(s)\n", .{self.fixed_file_count});
        }

        try self.writer.flush();
    }

    /// Returns one when diagnostics remain and zero otherwise.
    ///
    /// ```zig
    /// const status = reporter.exitCode();
    /// ```
    pub fn exitCode(self: Reporter) u8 {
        if (self.violation_count != 0) {
            return 1;
        }

        return 0;
    }

    fn writeViolation(self: *Reporter, path: []const u8, violation: diagnostic.Violation) !void {
        try self.writer.print("{s}:{d}:{d}: error: ", .{ path, violation.line, violation.column });

        switch (violation.rule) {
            .invalid_syntax => try self.writer.writeAll("source contains invalid Zig syntax [codestyle/invalid-syntax]\n"),
            .maximum_parameter_count => try self.writer.print("function has {d} parameters; maximum is 3 [codestyle/maximum-parameter-count]\n", .{violation.detail}),
            .single_line_function_signature => try self.writer.writeAll("function signature must be written on one line [codestyle/single-line-function-signature]\n"),
            .trailing_parameter_comma => try self.writer.writeAll("function parameter list must not have a trailing comma [codestyle/trailing-parameter-comma]\n"),
            .braced_if_branch => try self.writer.writeAll("if and else branches must use blocks [codestyle/braced-if-branch]\n"),
        }
    }
};

test "writes diagnostics, summaries, and a failing exit code" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var reporter: Reporter = .{ .writer = &output.writer };
    try reporter.report("source.zig", &.{.{
        .rule = .maximum_parameter_count,
        .line = 3,
        .column = 4,
        .detail = 5,
    }});
    reporter.recordFixed();
    try reporter.finish();

    try std.testing.expectEqual(@as(u8, 1), reporter.exitCode());
    try std.testing.expectEqualStrings(
        "source.zig:3:4: error: function has 5 parameters; maximum is 3 [codestyle/maximum-parameter-count]\n" ++
            "codestyle: fixed 1 file(s)\n",
        output.written(),
    );
}
