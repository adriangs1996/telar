const std = @import("std");
const ViolationType = @import("Violation.zig");
const Reporter = @This();

writer: *std.Io.Writer,
violation_count: usize = 0,
fixed_file_count: usize = 0,

/// Writes compiler-compatible diagnostics for one source file.
///
/// ```zig
/// try reporter.report("src/main.zig", violations);
/// ```
pub fn report(self: *Reporter, path: []const u8, violations: []const ViolationType) !void {
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

fn writeViolation(self: *Reporter, path: []const u8, violation: ViolationType) !void {
    try self.writer.print("{s}:{d}:{d}: error: ", .{ path, violation.line, violation.column });

    switch (violation.rule) {
        .invalid_syntax => try self.writer.writeAll("source contains invalid Zig syntax [codestyle/invalid-syntax]\n"),
        .maximum_parameter_count => try self.writer.print("function has {d} parameters; maximum is 3 [codestyle/maximum-parameter-count]\n", .{violation.detail}),
        .single_line_function_signature => try self.writer.writeAll("function signature must be written on one line [codestyle/single-line-function-signature]\n"),
        .trailing_parameter_comma => try self.writer.writeAll("function parameter list must not have a trailing comma [codestyle/trailing-parameter-comma]\n"),
        .braced_if_branch => try self.writer.writeAll("if and else branches must use blocks [codestyle/braced-if-branch]\n"),
        .ordinary_struct_declaration => try self.writer.writeAll("move this ordinary struct into its own implicit PascalCase file [codestyle/ordinary-struct-declaration]\n"),
        .type_file_name => try self.writer.writeAll("a concrete type file must use PascalCase [codestyle/type-file-name]\n"),
        .namespace_file_name => try self.writer.writeAll("a function/enum/union namespace must use snake_case [codestyle/namespace-file-name]\n"),
        .generic_constructor => try self.writer.writeAll("export type constructors as Type in GenericName.zig [codestyle/generic-constructor]\n"),
        .generic_file => try self.writer.writeAll("GenericName.zig must expose exactly one public Type(...) type function [codestyle/generic-file]\n"),
        .generic_import => try self.writer.writeAll("import .Type directly with a Generic-prefixed constructor alias [codestyle/generic-import]\n"),
        .dedicated_layout_file => try self.writer.writeAll("an explicit packed/extern layout requires a dedicated type file [codestyle/dedicated-layout-file]\n"),
    }
}
