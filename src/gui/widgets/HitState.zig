const core = @import("telar-core");
bands: @import("Bands.zig") = .{},
hits: @import("HitMap.zig") = .{},
band_hits: @import("BandHitMap.zig") = .{},
sidebar_regions: @import("SidebarRegions.zig") = .{},
workspace: ?core.WorkspaceId = null,
