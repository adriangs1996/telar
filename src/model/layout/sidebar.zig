//! Shared sidebar sizing policy for semantic state and presentation geometry.

const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");
const std = @import("std");

pub const minimum_width: u16 = 42;
pub const default_width: u16 = minimum_width;
pub const minimum_workbench_width: u16 = 20;
pub const resize_step: u16 = 2;

pub const Direction = @import("../types/SidebarDirection.zig").SidebarDirection;

/// Returns the visible width while retaining the caller's preferred width.
///
/// ```zig
/// const width = actualWidth(120, true, 70);
/// ```
pub fn actualWidth(host_width: u16, visible: bool, preferred_width: u16) u16 {
    if (!visible or host_width < minimum_width + minimum_workbench_width) {
        return 0;
    }

    return std.math.clamp(
        preferred_width,
        minimum_width,
        maximumWidth(host_width),
    );
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

    return std.math.clamp(
        requested_width,
        minimum_width,
        maximumWidth(host_width),
    );
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
    try std.testing.expectEqual(@as(u16, 0), actualWidth(
        61,
        true,
        default_width,
    ));
    try std.testing.expectEqual(@as(u16, minimum_width), actualWidth(
        62,
        true,
        default_width,
    ));
    try std.testing.expectEqual(@as(u16, minimum_width), actualWidth(
        120,
        true,
        default_width,
    ));
    try std.testing.expectEqual(@as(u16, 64), step(
        120,
        62,
        .wider,
    ));
    try std.testing.expectEqual(@as(u16, 42), clampInteractive(120, 1));
}

/// Commits an explicit sidebar preference. Repeated values preserve the
/// chrome revision and produce no projection work.
///
/// ```zig
/// const change = sidebar.setVisible(model, false) orelse return;
/// ```
pub fn setVisible(model: *ClientModel, visible: bool) ?model_data.SidebarLayout {
    return commitLayout(model, visible, model.sidebar_width);
}

/// Toggles the sidebar preference and advances only the chrome revision.
///
/// ```zig
/// const change = sidebar.toggle(model);
/// ```
pub fn toggle(model: *ClientModel) model_data.SidebarLayout {
    return setVisible(model, !model.sidebar_visible).?;
}

/// Commits an exact pointer-selected width within current host geometry.
///
/// ```zig
/// const change = sidebar.setWidth(model, 70) orelse return;
/// ```
pub fn setWidth(model: *ClientModel, requested_width: u16) ?model_data.SidebarLayout {
    const width = model_data.sidebar.clampInteractive(model.host.host_size.cols, requested_width);

    return commitLayout(model, model.sidebar_visible, width);
}

/// Moves the preferred width by one keybinding step.
///
/// ```zig
/// const change = sidebar.stepWidth(model, .wider) orelse return;
/// ```
pub fn stepWidth(model: *ClientModel, direction: model_data.SidebarDirection) ?model_data.SidebarLayout {
    const width = model_data.sidebar.step(model.host.host_size.cols, model.sidebar_width, direction);

    return commitLayout(model, model.sidebar_visible, width);
}

/// Restores server-retained sidebar state without losing a preference
/// merely because the current terminal is temporarily narrow.
///
/// ```zig
/// const change = sidebar.restoreLayout(model, true, 73) orelse return;
/// ```
pub fn restoreLayout(model: *ClientModel, visible: bool, preferred_width: u16) ?model_data.SidebarLayout {
    const width = @max(model_data.sidebar.minimum_width, preferred_width);

    return commitLayout(model, visible, width);
}

fn commitLayout(model: *ClientModel, visible: bool, width: u16) ?model_data.SidebarLayout {
    if (model.sidebar_visible == visible and model.sidebar_width == width) {
        return null;
    }

    model.sidebar_visible = visible;
    model.sidebar_width = width;
    model.chrome_revision +%= 1;

    return .{
        .visible = visible,
        .width = width,
        .chrome_revision = model.chrome_revision,
    };
}
