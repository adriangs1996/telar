const PointerCapture = @import("PointerCapture.zig");

pub const Owner = union(enum) {
    shared,
    child: PointerCapture,
    link,
    discarded,
};
