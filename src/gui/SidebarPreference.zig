//! The GUI's sidebar width preference in logical pixels: disposable host
//! state seeded from `gui.sidebar.width`, moved by the keyboard and the
//! pointer, and replaced when a reload changes the configured value. It is
//! never persisted; the Lua file is the durable form.
const std = @import("std");
const client = @import("telar-client");
const SidebarBand = @import("widgets/SidebarBand.zig");
const SidebarRequest = @import("widgets/SidebarRequest.zig");
const Preference = @This();

logical: f32 = client.GuiSidebar.default_width,
/// The configured width the preference was last taken from.
configured: f32 = client.GuiSidebar.default_width,
/// The band the last measurement resolved; interactive changes clamp to it.
band: SidebarBand = .{},

/// Example: `gui.sidebar = SidebarPreference.init(options.gui.sidebar.width);`
pub fn init(configured: f32) Preference {
    return .{ .logical = configured, .configured = configured };
}

/// The request the renderer measures with.
/// Example: `renderer.sidebar_request = gui.sidebar.request(model.sidebarVisible());`
pub fn request(preference: *const Preference, visible: bool) SidebarRequest {
    return .{ .visible = visible, .logical_width = preference.logical };
}

/// Retains the resolved band so later steps and drags clamp to this window.
/// Example: `gui.sidebar.observe(renderer.sidebar);`
pub fn observe(preference: *Preference, band: SidebarBand) void {
    preference.band = band;
}

/// Moves the preference by one keyboard step; false when the bounds held it.
/// Example: `if (gui.sidebar.step(.right)) gui.chrome.invalidate();`
pub fn step(preference: *Preference, direction: client.SidebarDirection) bool {
    const delta: f32 = switch (direction) {
        .left => -SidebarBand.logical_step,
        .right => SidebarBand.logical_step,
    };
    return preference.set(preference.band.clampLogical(preference.logical + delta));
}

/// Adopts the exact width a drag selected, in device pixels.
/// Example: `if (gui.sidebar.drag(width)) gui.chrome.invalidate();`
pub fn drag(preference: *Preference, physical: u32) bool {
    return preference.set(@as(f32, @floatFromInt(preference.band.clamp(physical))) / preference.band.scale);
}

/// Follows a reload: a changed configured width replaces the preference, an
/// unchanged one keeps what the person chose interactively.
/// Example: `_ = gui.sidebar.reload(renderer.config.sidebar.width);`
pub fn reload(preference: *Preference, configured: f32) bool {
    if (configured == preference.configured) {
        return false;
    }

    preference.configured = configured;
    return preference.set(configured);
}

fn set(preference: *Preference, logical: f32) bool {
    if (logical == preference.logical) {
        return false;
    }

    preference.logical = logical;
    return true;
}

test "the preference steps drags and reloads inside the observed band" {
    var preference = init(284);
    preference.observe(SidebarBand.resolve(.{ .visible = true }, .{ .width = 2000, .cell_width = 10 }));
    try std.testing.expect(preference.step(.right));
    try std.testing.expectEqual(@as(f32, 300), preference.logical);
    try std.testing.expect(preference.step(.left));
    try std.testing.expect(preference.step(.left));
    try std.testing.expectEqual(@as(f32, 268), preference.logical);
    try std.testing.expect(preference.drag(1000));
    try std.testing.expectEqual(@as(f32, 480), preference.logical);
    try std.testing.expect(!preference.step(.right));
    try std.testing.expect(preference.drag(1));
    try std.testing.expectEqual(@as(f32, 220), preference.logical);
    try std.testing.expect(!preference.step(.left));
    try std.testing.expect(!preference.reload(284));
    try std.testing.expectEqual(@as(f32, 220), preference.logical);
    try std.testing.expect(preference.reload(320));
    try std.testing.expectEqual(@as(f32, 320), preference.logical);
    preference.observe(SidebarBand.resolve(.{ .visible = true }, .{ .width = 4000, .cell_width = 20, .scale = 2 }));
    try std.testing.expect(preference.drag(700));
    try std.testing.expectEqual(@as(f32, 350), preference.logical);
    try std.testing.expectEqual(true, preference.request(true).visible);
    try std.testing.expectEqual(@as(f32, 350), preference.request(false).logical_width);
}
