//! Shared sidebar sizing policy for semantic state and presentation geometry.

const std = @import("std");

pub const minimum_width: u16 = 42;
pub const default_width: u16 = minimum_width;
pub const minimum_workbench_width: u16 = 20;
pub const resize_step: u16 = 2;

pub const Direction = enum {
    narrower,
    wider,
};

/// Returns the visible width while retaining the caller's preferred width.
///
/// ```zig
/// const width = actualWidth(120, true, 70);
/// ```
pub fn actualWidth(host_width: u16, visible: bool, preferred_width: u16) u16 {
    if (!visible or host_width < minimum_width + minimum_workbench_width) {
        return 0;
    }

    return std.math.clamp(preferred_width, minimum_width, maximumWidth(host_width));
}

/// Clamps one interactive resize to the useful range of the current host.
///
/// ```zig
/// const width = clampInteractive(120, 118);
/// ```
pub fn clampInteractive(host_width: u16, requested_width: u16) u16 {
    if (host_width < minimum_width + minimum_workbench_width) {
        return minimum_width;
    }

    return std.math.clamp(requested_width, minimum_width, maximumWidth(host_width));
}

/// Moves one preferred width by the keybinding step within current geometry.
///
/// ```zig
/// const wider = step(120, 62, .wider);
/// ```
pub fn step(host_width: u16, preferred_width: u16, direction: Direction) u16 {
    const current = clampInteractive(host_width, preferred_width);
    const requested = switch (direction) {
        .narrower => current -| resize_step,
        .wider => current +| resize_step,
    };

    return clampInteractive(host_width, requested);
}

fn maximumWidth(host_width: u16) u16 {
    return host_width - minimum_workbench_width;
}

test "sidebar sizing retains useful bounds" {
    try std.testing.expectEqual(minimum_width, default_width);
    try std.testing.expectEqual(@as(u16, 0), actualWidth(61, true, default_width));
    try std.testing.expectEqual(@as(u16, minimum_width), actualWidth(62, true, default_width));
    try std.testing.expectEqual(@as(u16, minimum_width), actualWidth(120, true, default_width));
    try std.testing.expectEqual(@as(u16, 64), step(120, 62, .wider));
    try std.testing.expectEqual(@as(u16, 42), clampInteractive(120, 1));
}
