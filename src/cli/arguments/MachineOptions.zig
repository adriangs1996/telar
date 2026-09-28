//! `telar machine add|remove|rename|enable|disable|list|check|setup`: the
//! saved machines in `machines.json`, and setting one up.
const std = @import("std");
const MachineOptions = @This();

pub const Action = enum { add, remove, rename, enable, disable, list, check, setup, receive_config };

/// Setup steps a person may leave out.
pub const SetupSkip = enum { agents, config, login };

action: Action,
/// The machine the action names; `list` names none. `setup` takes a label
/// or an SSH destination.
label: ?[*:0]const u8 = null,
/// `add`'s SSH destination or `rename`'s new label.
value: ?[*:0]const u8 = null,
color: ?[*:0]const u8 = null,
disabled: bool = false,
/// `add --check` reaches the machine before saving it.
check: bool = false,
json: bool = false,
/// `add --setup` sets the machine up once it is saved.
setup: bool = false,
/// `setup`'s label for a destination no profile names yet.
new_label: ?[*:0]const u8 = null,
/// `setup --confirm` asks on the terminal before it changes anything; the
/// window passes it, since one key press there starts setup.
confirm: bool = false,
/// A telar executable built for the machine, for development builds.
binary: ?[*:0]const u8 = null,
skip: std.EnumSet(SetupSkip) = .initEmpty(),

/// Example: `const options = try MachineOptions.parse(args);`.
pub fn parse(args: []const [*:0]const u8) !MachineOptions {
    if (args.len == 0) {
        return error.MissingMachineAction;
    }

    // `receive-config` is what setup runs on the machine it sets up.
    const action_name = std.mem.span(args[0]);
    const action = if (std.mem.eql(u8, action_name, "receive-config"))
        .receive_config
    else
        std.meta.stringToEnum(Action, action_name) orelse return error.UnknownMachineAction;
    if (action == .receive_config and args.len != 1) {
        return error.UnknownMachineOption;
    }

    var options: MachineOptions = .{ .action = action };
    const positional_count: usize = switch (action) {
        .list, .receive_config => 0,
        .remove, .enable, .disable, .check, .setup => 1,
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
        const takes_setup = action == .setup or action == .add;
        if (std.mem.eql(u8, arg, "--json") and (action == .list or action == .check or takes_setup)) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--setup") and action == .add) {
            options.setup = true;
        } else if (std.mem.eql(u8, arg, "--confirm") and action == .setup) {
            options.confirm = true;
        } else if (std.mem.eql(u8, arg, "--label") and action == .setup) {
            options.new_label = try optionValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--binary") and takes_setup) {
            options.binary = try optionValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--skip") and takes_setup) {
            var names = std.mem.splitScalar(u8, std.mem.span(try optionValue(args, &index)), ',');
            while (names.next()) |name| {
                options.skip.insert(std.meta.stringToEnum(SetupSkip, name) orelse return error.UnknownSetupSkip);
            }
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

    // Setup options beside `add` need `--setup`, which may come after them.
    if (action == .add and !options.setup and (options.binary != null or options.skip.count() != 0)) {
        return error.SetupOptionWithoutSetup;
    }

    return options;
}

// The argument after an option that takes one.
fn optionValue(args: []const [*:0]const u8, index: *usize) ![*:0]const u8 {
    index.* += 1;
    if (index.* == args.len) {
        return error.MissingMachineArgument;
    }

    return args[index.*];
}

test "machine add takes a label, a destination and its options" {
    const options = try MachineOptions.parse(&.{ "add", "box", "dev@box", "--color", "red", "--check", "--disabled" });

    try std.testing.expectEqual(Action.add, options.action);
    try std.testing.expectEqualStrings("box", std.mem.span(options.label.?));
    try std.testing.expectEqualStrings("dev@box", std.mem.span(options.value.?));
    try std.testing.expectEqualStrings("red", std.mem.span(options.color.?));
    try std.testing.expect(options.check and options.disabled);
}

test "machine setup takes a label or destination and its options" {
    const options = try MachineOptions.parse(&.{ "setup", "dev@box", "--label", "box", "--binary", "/tmp/telar", "--skip", "login,config", "--json" });

    try std.testing.expectEqual(Action.setup, options.action);
    try std.testing.expectEqualStrings("dev@box", std.mem.span(options.label.?));
    try std.testing.expectEqualStrings("box", std.mem.span(options.new_label.?));
    try std.testing.expectEqualStrings("/tmp/telar", std.mem.span(options.binary.?));
    try std.testing.expect(options.skip.contains(.login) and options.skip.contains(.config) and !options.skip.contains(.agents));
    try std.testing.expect(options.json);
    try std.testing.expect(!options.confirm);
    try std.testing.expect((try MachineOptions.parse(&.{ "setup", "box", "--confirm" })).confirm);
    try std.testing.expectError(error.UnknownMachineOption, MachineOptions.parse(&.{ "add", "box", "dev@box", "--confirm" }));

    const added = try MachineOptions.parse(&.{ "add", "box", "dev@box", "--skip", "agents", "--setup" });
    try std.testing.expect(added.setup and added.skip.contains(.agents));

    try std.testing.expectError(error.UnknownSetupSkip, MachineOptions.parse(&.{ "setup", "box", "--skip", "everything" }));
    try std.testing.expectError(error.SetupOptionWithoutSetup, MachineOptions.parse(&.{ "add", "box", "dev@box", "--binary", "/tmp/telar" }));
    try std.testing.expectError(error.UnknownMachineOption, MachineOptions.parse(&.{ "check", "box", "--binary", "/tmp/telar" }));
    try std.testing.expectError(error.MissingMachineArgument, MachineOptions.parse(&.{"setup"}));
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
