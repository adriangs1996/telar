const core = @import("telar-core");
const root = @import("../environment/environment.zig");
const HostAppearance = @import("HostAppearance.zig").HostAppearance;
const pacing = @import("pacing");
const std = @import("std");
const HostCapabilities = @This();

images: root.Support = .unknown,
window_width_px: u32 = 0,
window_height_px: u32 = 0,
cell_width_px: u32 = 0,
cell_height_px: u32 = 0,
pointer_pixels: root.Support = .unknown,
appearance: HostAppearance = .unknown,
terminal_colors: core.TerminalColors = .{},
/// The cadence the host presents frames at, within the wire bounds. The
/// runtime paces this client's cell frames to it.
frame_interval_ns: u64 = pacing.pace.default_interval,

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
