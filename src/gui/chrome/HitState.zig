const client = @import("telar-client");
const Regions = @import("Regions.zig");

regions: Regions = Regions.calculate(0, 0, .{ .visible = false, .preferred_width = client.default_width }),
hits: @import("HitMap.zig") = .{},
