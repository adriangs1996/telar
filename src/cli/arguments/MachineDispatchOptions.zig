//! `telar --machine LABEL COMMAND…`: run one telar command on a saved
//! machine; without a command, or with window options, open a window that
//! shows that machine. The flag is only ever read from argv, never from
//! the environment, so a pane never passes its machine to a child.
const std = @import("std");
const MachineDispatchOptions = @This();

const flag = "--machine";

label: [:0]const u8,
/// The command as its own argv: element 0 stands in for the program name.
argv: []const [*:0]const u8,

/// Recognizes the flag as the first argument. Null means argv does not
/// dispatch.
///
/// ```zig
/// const dispatch = try MachineDispatchOptions.parse(args) orelse return null;
/// ```
pub fn parse(args: []const [*:0]const u8) !?MachineDispatchOptions {
    if (args.len < 2) {
        return null;
    }

    const first = std.mem.span(args[1]);
    if (std.mem.eql(u8, first, flag)) {
        if (args.len < 3) {
            return error.MissingMachineLabel;
        }

        return try finish(std.mem.span(args[2]), args[2..]);
    }

    if (std.mem.startsWith(u8, first, flag ++ "=")) {
        return try finish(std.mem.span(args[1] + flag.len + 1), args[1..]);
    }

    return null;
}

fn finish(label: [:0]const u8, argv: []const [*:0]const u8) !MachineDispatchOptions {
    if (label.len == 0) {
        return error.MissingMachineLabel;
    }

    return .{
        .label = label,
        .argv = argv,
    };
}

test "the machine flag splits the label from the command" {
    const spaced = (try MachineDispatchOptions.parse(&.{ "telar", "--machine", "box", "pane", "list" })).?;
    try std.testing.expectEqualStrings("box", spaced.label);
    try std.testing.expectEqual(@as(usize, 3), spaced.argv.len);
    try std.testing.expectEqualStrings("pane", std.mem.span(spaced.argv[1]));

    const joined = (try MachineDispatchOptions.parse(&.{ "telar", "--machine=box", "pane", "list" })).?;
    try std.testing.expectEqualStrings("box", joined.label);
    try std.testing.expectEqualStrings("list", std.mem.span(joined.argv[2]));
}

test "the machine flag needs a label and a command" {
    try std.testing.expectEqual(@as(?MachineDispatchOptions, null), try MachineDispatchOptions.parse(&.{ "telar", "pane", "list" }));
    try std.testing.expectError(error.MissingMachineLabel, MachineDispatchOptions.parse(&.{ "telar", "--machine" }));
    try std.testing.expectError(error.MissingMachineLabel, MachineDispatchOptions.parse(&.{ "telar", "--machine=", "pane" }));
    const window = (try MachineDispatchOptions.parse(&.{ "telar", "--machine", "box" })).?;
    try std.testing.expectEqual(@as(usize, 1), window.argv.len);
}
