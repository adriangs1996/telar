//! The GUI's sidebar width preference in logical pixels: disposable host
//! state seeded from `gui.sidebar.width`, moved by the keyboard and the
//! pointer, and replaced when a reload changes the configured value. It is
//! never persisted; the Lua file is the durable form.
const data = @import("model");
const client = @import("telar-client");
const SidebarBand = @import("widgets/SidebarBand.zig");
const SidebarRequest = @import("widgets/SidebarRequest.zig");
const Preference = @This();

logical: f32 = client.GuiSidebar.default_width,
/// The configured width the preference was last taken from.
configured: f32 = client.GuiSidebar.default_width,
/// The band the last measurement resolved; interactive changes clamp to it.
band: SidebarBand = .{},

/// Example: `gui.model.sidebar = SidebarPreference.init(options.gui.sidebar.width);`
pub fn init(configured: f32) Preference {
    return .{ .logical = configured, .configured = configured };
}

/// The request the renderer measures with.
/// Example: `renderer.sidebar_request = gui.model.sidebar.request(model.sidebar_visible);`
pub fn request(self: *const Preference, visible: bool) SidebarRequest {
    return .{ .visible = visible, .logical_width = self.logical };
}

/// Retains the resolved band so later steps and drags clamp to this window.
/// Example: `gui.model.sidebar.observe(renderer.sidebar);`
pub fn observe(self: *Preference, band: SidebarBand) void {
    self.band = band;
}

/// Moves the preference by one keyboard step; false when the bounds held it.
/// Example: `if (gui.model.sidebar.step(.right)) gui.model.chrome.invalidate();`
pub fn step(self: *Preference, direction: data.actions.SidebarDirection) bool {
    const delta: f32 = switch (direction) {
        .left => -SidebarBand.logical_step,
        .right => SidebarBand.logical_step,
    };
    return self.set(self.band.clampLogical(self.logical + delta));
}

/// Adopts the exact width a drag selected, in device pixels.
/// Example: `if (gui.model.sidebar.drag(width)) gui.model.chrome.invalidate();`
pub fn drag(self: *Preference, physical: u32) bool {
    return self.set(@as(f32, @floatFromInt(self.band.clamp(physical))) / self.band.scale);
}

/// Follows a reload: a changed configured width replaces the preference, an
/// unchanged one keeps what the person chose interactively.
/// Example: `_ = gui.model.sidebar.reload(renderer.config.sidebar.width);`
pub fn reload(self: *Preference, configured: f32) bool {
    if (configured == self.configured) {
        return false;
    }

    self.configured = configured;
    return self.set(configured);
}

fn set(self: *Preference, logical: f32) bool {
    if (logical == self.logical) {
        return false;
    }

    self.logical = logical;
    return true;
}
