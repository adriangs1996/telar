//! The command tabs a configuration generation's actions open. An action
//! holds a `CommandTabRef` into this table instead of the argv, so the
//! Action union, which bindings, bar components and callback results all
//! hold, stays small. Equal commands share one row, so a callback that
//! returns the same command on every press takes one row.
const data = @import("model");
const core = @import("telar-core");
const CommandTabs = @This();

/// Distinct command tabs one configuration opens, from its bindings, its
/// components and what its callbacks return.
pub const capacity = 32;
pub const limit = core.Limit.declare("config.command_tabs", "command tabs", capacity);

items: [capacity]data.CommandTab = undefined,
count: u8 = 0,

/// Keeps `command` and returns its row, sharing an equal one.
///
/// ```zig
/// const id = try generation.snapshot.command_tabs.add(&command);
/// ```
pub fn add(self: *CommandTabs, command: *const data.CommandTab) !u8 {
    for (self.items[0..self.count], 0..) |*existing, index| {
        if (existing.eql(command)) {
            return @intCast(index);
        }
    }

    if (self.count == capacity) {
        return error.TooManyCommandTabs;
    }

    self.items[self.count] = command.*;
    self.count += 1;
    return self.count - 1;
}

/// The command a reference names in the generation `number`, or null when
/// it belongs to another generation.
/// Example: `const command = tabs.find(generation.number, ref) orelse return;`
pub fn find(self: *const CommandTabs, number: u64, ref: data.CommandTabRef) ?*const data.CommandTab {
    if (ref.generation != number) {
        return null;
    }

    return self.at(ref.id);
}

/// The command in row `id`, for a reader that already holds this table's
/// generation, such as a configuration query.
/// Example: `const command = snapshot.command_tabs.at(ref.id) orelse return;`
pub fn at(self: *const CommandTabs, id: u8) ?*const data.CommandTab {
    if (id >= self.count) {
        return null;
    }

    return &self.items[id];
}
