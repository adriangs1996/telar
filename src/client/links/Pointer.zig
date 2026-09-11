const Command = @import("PointerCommand.zig");
const TargetType = @import("LinkTarget.zig");
const Outcome = @import("Outcome.zig");
const Pointer = @This();

owned: bool = false,

/// Claims a left-button gesture only when its press begins over a link.
///
/// ```zig
/// const outcome = pointer.handle(command, target);
/// ```
pub fn handle(pointer: *Pointer, command: Command, target: ?TargetType) Outcome {
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
