//! Edge styles for one Unicode box intersection.
const box_style = @import("box_style.zig");

pub const Lines = packed struct(u8) {
    up: box_style.Style = .none,
    right: box_style.Style = .none,
    down: box_style.Style = .none,
    left: box_style.Style = .none,
};
