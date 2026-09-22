const PointerCommand = @import("../application/input/PointerCommand.zig");
const action_module = @import("../input/action.zig");

pub const PaneMouseCommand = union(enum) {
    pointer: PointerCommand,
    focused_scroll: action_module.ScrollDirection,
};
