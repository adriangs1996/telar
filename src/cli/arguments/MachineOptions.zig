//! `telar machine add|remove|rename|enable|disable|list|check`: the saved
//! machines in `machines.json`.
const std = @import("std");
const MachineOptions = @This();

pub const Action = enum { add, remove, rename, enable, disable, list, check };

action: Action,
/// The machine the action names; `list` names none.
label: ?[*:0]const u8 = null,
/// `add`'s SSH destination or `rename`'s new label.
value: ?[*:0]const u8 = null,
color: ?[*:0]const u8 = null,
disabled: bool = false,
/// `add --check` reaches the machine before saving it.
check: bool = false,
json: bool = false,

/// Example: `const options = try MachineOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !MachineOptions {
    if (args.len == 0) {
        return error.MissingMachineAction;
    }

    const action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownMachineAction;
    var options: MachineOptions = .{ .action = action };
    const positional_count: usize = switch (action) {
        .list => 0,
        .remove, .enable, .disable, .check => 1,
        .add, .rename => 2,
    };

    if (args.len < 1 + positional_count) {
        return error.MissingMachineArgument;
    }

    if (positional_count >= 1) {
        options.label = args[1];
    }

    if (positional_count == 2) {
        options.value = args[2];
    }

    var index = 1 + positional_count;
    while (index < args.len) : (index += 1) {
        const arg = std.mem.span(args[index]);
        if (std.mem.eql(u8, arg, "--json") and (action == .list or action == .check or action == .add)) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--color") and action == .add) {
            if (options.color != null) {
                return error.DuplicateColorOption;
            }

            index += 1;
            if (index == args.len) {
                return error.MissingMachineColor;
            }

            options.color = args[index];
        } else if (std.mem.eql(u8, arg, "--disabled") and action == .add) {
            options.disabled = true;
        } else if (std.mem.eql(u8, arg, "--check") and action == .add) {
            options.check = true;
        } else {
            return error.UnknownMachineOption;
        }
    }

    return options;
}

test "machine add takes a label, a destination and its options" {
    const options = try MachineOptions.parse(&.{ "add", "box", "dev@box", "--color", "red", "--check", "--disabled" });

    try std.testing.expectEqual(Action.add, options.action);
    try std.testing.expectEqualStrings("box", std.mem.span(options.label.?));
    try std.testing.expectEqualStrings("dev@box", std.mem.span(options.value.?));
    try std.testing.expectEqualStrings("red", std.mem.span(options.color.?));
    try std.testing.expect(options.check and options.disabled);
}

test "each action takes exactly its arguments" {
    try std.testing.expectEqual(Action.list, (try MachineOptions.parse(&.{ "list", "--json" })).action);
    try std.testing.expectEqualStrings("gpu", std.mem.span((try MachineOptions.parse(&.{ "rename", "box", "gpu" })).value.?));

    try std.testing.expectError(error.MissingMachineAction, MachineOptions.parse(&.{}));
    try std.testing.expectError(error.UnknownMachineAction, MachineOptions.parse(&.{"connect"}));
    try std.testing.expectError(error.MissingMachineArgument, MachineOptions.parse(&.{ "add", "box" }));
    try std.testing.expectError(error.UnknownMachineOption, MachineOptions.parse(&.{ "remove", "box", "--color", "red" }));
    try std.testing.expectError(error.UnknownMachineOption, MachineOptions.parse(&.{ "list", "extra" }));
    try std.testing.expectError(error.MissingMachineColor, MachineOptions.parse(&.{ "add", "box", "dev@box", "--color" }));
}
