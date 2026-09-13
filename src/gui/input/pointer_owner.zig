pub const Owner = union(enum) {
    shared,
    child: @import("PointerCapture.zig"),
    link,
    discarded,
};
