const Command = @import("PointerCommand.zig");
const TargetType = @import("LinkTarget.zig");
const Outcome = @import("Outcome.zig");
const Pointer = @This();

owned: bool = false,

/// Claims a left- or right-button gesture only when its press begins over a link.
///
/// ```zig
/// const outcome = pointer.handle(command, target);
/// ```
pub fn handle(self: *Pointer, command: Command, target: ?TargetType) Outcome {
    if (self.owned) {
        if (command.kind == .release) {
            self.owned = false;
        } else if (command.kind == .press) {
            self.owned = false;
        } else {
            return .{
                .consumed = command.kind == .drag,
            };
        }

        if (command.kind == .release) {
            return .{
                .consumed = true,
            };
        }
    }

    if (command.kind != .press or (!command.left_button and !command.right_button)) {
        return .{};
    }

    const link_target = target orelse return .{};
    self.owned = true;

    if (command.right_button) {
        return .{
            .consumed = true,
            .copy = link_target,
        };
    }

    return .{
        .consumed = true,
        .open = link_target,
    };
}
