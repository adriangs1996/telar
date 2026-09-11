const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const Io = std.Io;

pub const Reporter = @import("Reporter.zig");

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
