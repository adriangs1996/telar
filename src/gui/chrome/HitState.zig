const Regions = @import("Regions.zig");

regions: Regions = Regions.calculate(0, 0),
bands: @import("Bands.zig") = .{},
hits: @import("HitMap.zig") = .{},
band_hits: @import("BandHitMap.zig") = .{},
