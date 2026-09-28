//! The flags only the headless client takes. They come first; the client's
//! own options (`--config`, `--no-config`, `--remote`, `-- COMMAND`) follow.
const std = @import("std");
const input_protocol = @import("input_protocol.zig");
const HeadlessOptions = @This();

pub const default_cols = 120;
pub const default_rows = 40;

cols: u16 = default_cols,
rows: u16 = default_rows,
/// Where the exit trace goes: frames, input, marks and host requests.
trace_path: ?[]const u8 = null,
/// Where the exit dump goes: what a window would have shown.
dump_path: ?[]const u8 = null,
/// How many arguments these flags used.
consumed: usize = 0,

/// Parses `--size COLSxROWS`, `--trace PATH` and `--dump PATH` from the
/// front of `args`.
///
/// ```zig
/// const options = try HeadlessOptions.parse(args);
/// const rest = args[options.consumed..];
/// ```
pub fn parse(args: []const [*:0]const u8) !HeadlessOptions {
    var options: HeadlessOptions = .{};
    while (options.consumed < args.len) {
        const flag = std.mem.span(args[options.consumed]);
        const Flag = enum { size, trace, dump };
        const which: Flag = if (std.mem.eql(u8, flag, "--size"))
            .size
        else if (std.mem.eql(u8, flag, "--trace"))
            .trace
        else if (std.mem.eql(u8, flag, "--dump"))
            .dump
        else
            break;

        if (options.consumed + 1 >= args.len) {
            return error.MissingHeadlessValue;
        }

        const value = std.mem.span(args[options.consumed + 1]);
        switch (which) {
            .size => {
                const size = try input_protocol.parseSize(value);
                options.cols = size.cols;
                options.rows = size.rows;
            },
            .trace => options.trace_path = value,
            .dump => options.dump_path = value,
        }

        options.consumed += 2;
    }

    return options;
}

test "headless flags come first and leave the client's options" {
    const args = [_][*:0]const u8{ "--size", "80x24", "--trace", "t.json", "--no-config", "--", "cat" };
    const options = try parse(&args);

    try std.testing.expectEqual(@as(u16, 80), options.cols);
    try std.testing.expectEqualStrings("t.json", options.trace_path.?);
    try std.testing.expectEqual(@as(usize, 4), options.consumed);
    try std.testing.expectError(error.MissingHeadlessValue, parse(&.{"--dump"}));
}
