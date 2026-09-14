const client = @import("telar-client");
const Regions = @import("Regions.zig");

regions: Regions = Regions.calculate(0, 0, .{ .visible = false, .preferred_width = client.default_width }),
bands: @import("Bands.zig") = .{},
hits: @import("HitMap.zig") = .{},
band_hits: @import("BandHitMap.zig") = .{},
