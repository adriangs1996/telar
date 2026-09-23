const core = @import("telar-core");
const root = @import("../environment/environment.zig");
const HostAppearance = @import("../types/HostAppearance.zig").HostAppearance;
const HostCapabilityObservation = @import("../types/HostCapabilityObservation.zig").HostCapabilityObservation;
const HostCapabilitySupport = @import("../types/HostCapabilitySupport.zig").HostCapabilitySupport;
const std = @import("std");
const HostCapabilities = @This();

images: root.Support = .unknown,
agent_panes: bool = false,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
cell_width_px: u32 = 0,
cell_height_px: u32 = 0,
pointer_pixels: root.Support = .unknown,
appearance: HostAppearance = .unknown,
terminal_colors: core.TerminalColors = .{},

/// Resolves one cell size, preferring the host's explicit cell report.
///
/// ```zig
/// const cell_size = capabilities.cellSize(80, 24);
/// ```
pub fn cellSize(self: *const HostCapabilities, cols: u16, rows: u16) struct { width: u16, height: u16 } {
    const width = if (self.cell_width_px != 0)
        self.cell_width_px
    else if (cols != 0)
        self.window_width_px / cols
    else
        0;
    const height = if (self.cell_height_px != 0)
        self.cell_height_px
    else if (rows != 0)
        self.window_height_px / rows
    else
        0;

    return .{
        .width = std.math.cast(u16, width) orelse 0,
        .height = std.math.cast(u16, height) orelse 0,
    };
}

/// Returns the complete capability value after one recognized reply.
///
/// ```zig
/// const next = capabilities.withObservation(.{ .pointer_pixels = .supported });
/// ```
pub fn withObservation(self: HostCapabilities, observation: HostCapabilityObservation) HostCapabilities {
    var next = self;
    switch (observation) {
        .images => |support| next.images = observedSupport(support),
        .window_pixels => |size| {
            next.window_width_px = size.width;
            next.window_height_px = size.height;
        },
        .cell_pixels => |size| {
            next.cell_width_px = size.width;
            next.cell_height_px = size.height;
        },
        .pointer_pixels => |support| next.pointer_pixels = observedSupport(support),
        .foreground => |color| next.terminal_colors.foreground = .{ color.r, color.g, color.b },
        .background => |color| {
            next.terminal_colors.background = .{ color.r, color.g, color.b };
            // ITU-R BT.601 luma; the midpoint splits light from dark.
            const luma = 299 * @as(u32, color.r) + 587 * @as(u32, color.g) + 114 * @as(u32, color.b);
            next.appearance = if (luma >= 128_000) .light else .dark;
        },
    }

    return next;
}

fn observedSupport(support: HostCapabilitySupport) root.Support {
    return switch (support) {
        .unsupported => .unsupported,
        .supported => .supported,
    };
}
