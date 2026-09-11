const Pointer = @This();
const Command = @import("Command.zig");
const target_mod = @import("root.zig").target;
const Outcome = @import("Outcome.zig");
owned: bool = false,

/// Claims a left-button gesture only when its press begins over a link.
///
/// ```zig
/// const outcome = pointer.handle(command, target);
/// ```
pub fn handle(pointer: *Pointer, command: Command, target: ?target_mod.Target) Outcome {
    if (pointer.owned) {
        if (command.kind == .release) {
            pointer.owned = false;
        } else if (command.kind == .press) {
            pointer.owned = false;
        } else {
            return .{ .consumed = command.kind == .drag };
        }

        if (command.kind == .release) {
            return .{ .consumed = true };
        }
    }

    if (command.kind != .press or !command.left_button) {
        return .{};
    }

    const link_target = target orelse return .{};
    pointer.owned = true;

    return .{ .consumed = true, .open = link_target };
}
