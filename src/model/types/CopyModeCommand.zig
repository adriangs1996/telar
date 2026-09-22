const KeyType = @import("../input/Key.zig");
const PointerMotionType = @import("../input/PointerMotion.zig");
const CopyModeMatches = @import("../state/CopyModeMatches.zig");

pub const CopyModeCommand = union(enum) {
    key: KeyType,
    pointer: PointerMotionType,
    cancel_pointer,
    vertical: i32,
    matches: CopyModeMatches,
    leave,
};
