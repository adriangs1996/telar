const core = @import("telar-core");
const Bands = @import("Bands.zig");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const SidebarRegions = @import("SidebarRegions.zig");
const data = @import("model");
const BarOverflow = data.BarOverflow;
const gfx = @import("gfx");
const Rect = gfx.Rect;
const HitState = @This();

/// An area that holds nothing.
const no_area: Rect = .{
    .x = 0,
    .y = 0,
    .width = 0,
    .height = 0,
};
bands: Bands = .{},
hits: HitMap = .{},
band_hits: BandHitMap = .{},
sidebar_regions: SidebarRegions = .{},
workspace: ?core.WorkspaceId = null,
/// The tab strip's area; while the pointer rests in it the strip keeps its layout.
tab_strip: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
/// The open bar panel; a press outside it closes the panel.
bar_panel: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
bar_overflow: BarOverflow = .{},

/// Empties the chrome's targets for the next frame without touching the
/// rows of its tables. Example: `hits.reset();`
pub fn reset(self: *HitState) void {
    self.bands = .{};
    self.hits.len = 0;
    self.hits.dropped = 0;
    self.band_hits.len = 0;
    self.band_hits.dropped = 0;
    self.sidebar_regions = .{};
    self.workspace = null;
    self.tab_strip = no_area;
    self.bar_panel = no_area;
    self.bar_overflow = .{};
}
