//! Edge styles for one Unicode box intersection.
const Style = @import("box_style.zig").Style;

pub const Lines = packed struct(u8) {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,
};
