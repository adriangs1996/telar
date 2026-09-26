const core = @import("telar-core");
const Bands = @import("Bands.zig");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const SidebarRegions = @import("SidebarRegions.zig");
const data = @import("model");
const BarOverflow = data.BarOverflow;
const gfx = @import("gfx");
const Rect = gfx.Rect;
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
