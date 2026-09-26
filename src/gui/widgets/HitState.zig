const core = @import("telar-core");
const Bands = @import("Bands.zig");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const SidebarRegions = @import("SidebarRegions.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
bands: Bands = .{},
hits: HitMap = .{},
band_hits: BandHitMap = .{},
sidebar_regions: SidebarRegions = .{},
workspace: ?core.WorkspaceId = null,
/// The tab strip's area; while the pointer rests in it the strip keeps its layout.
tab_strip: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
