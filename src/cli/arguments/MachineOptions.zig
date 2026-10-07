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
