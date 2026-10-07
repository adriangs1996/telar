//! One entry of `client.picks`: where its options come from and the
//! command that receives the chosen one.
const BarCommand = @import("BarCommand.zig");
const CallbackRef = @import("CallbackRef.zig");
const PanelHeading = @import("PanelHeading.zig");
const std = @import("std");
const PickDefinition = @This();

/// The `on_select` argument that becomes the chosen value. Only a whole
/// argument is replaced, so the value is always one argv element and never
/// text inside another argument.
pub const choice_marker = "{}";

/// The pick's name and the title its list shows; a pick draws no mark,
/// icon or width.
heading: PanelHeading = .{},
/// Prints the options, one per line, or the text `items` parses. Null
/// when `items` alone lists them.
list: ?BarCommand = null,
/// The Lua table of options, or the function that returns them from the
/// list command's output.
items: ?CallbackRef = null,
/// Runs once with the chosen value in place of every `choice_marker`.
on_select: BarCommand = .{
    .generation = 0,
    .interval_ns = 0,
    .timeout_ms = 0,
},
/// Reruns the bar sources and the open panel after `on_select` succeeds.
refresh: bool = true,

/// The `on_select` argv with the chosen value in place of each marker. The
/// program itself is never replaced, so a choice cannot pick what runs.
///
/// ```zig
/// const command = try definition.selection("anthropic/claude-opus-5-5");
/// ```
pub fn selection(self: *const PickDefinition, value: []const u8) !BarCommand {
    var command: BarCommand = .{
        .generation = self.on_select.generation,
        .interval_ns = 0,
        .timeout_ms = self.on_select.timeout_ms,
    };

    for (0..self.on_select.argument_count) |index| {
        const argument = self.on_select.argument(index).?;
        const chosen = index != 0 and std.mem.eql(u8, argument, choice_marker);
        try command.appendArgument(if (chosen) value else argument);
    }

    return command;
}

/// Whether `on_select` names where the chosen value goes, outside the
/// program itself. Example: `if (!definition.receivesChoice()) return error.InvalidConfig;`
pub fn receivesChoice(self: *const PickDefinition) bool {
    for (1..self.on_select.argument_count) |index| {
        if (std.mem.eql(u8, self.on_select.argument(index).?, choice_marker)) {
            return true;
        }
    }

    return false;
}
