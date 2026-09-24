const keyinput = @import("keyinput");
const Key = keyinput.Key;
const PointerMotion = @import("../input/PointerMotion.zig");
const CopyModeMatches = @import("../state/CopyModeMatches.zig");

pub const CopyModeCommand = union(enum) {
    key: Key,
    pointer: PointerMotion,
    cancel_pointer,
    vertical: i32,
    matches: CopyModeMatches,
    leave,
};
