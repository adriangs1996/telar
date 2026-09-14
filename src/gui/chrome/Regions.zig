const core = @import("telar-core");
const Regions = @This();

full: core.Rect,
workbench: core.Rect,

/// The cell grid the workbench owns. Navigation, the status bar and the
/// sidebar band are pixels that `TerminalRenderer.measure` takes
/// off the window before this grid exists, so every cell here is a complete
/// terminal cell, the PTY never sees chrome and no column is split off.
/// Example: `const regions = Regions.calculate(120, 40);`
pub fn calculate(width: u16, height: u16) Regions {
    const full: core.Rect = .{ .w = width, .h = height };
    return .{ .full = full, .workbench = full };
}
