const Size = @import("Size.zig");
const ProviderAtlasInput = @This();

destination: []u8,
atlas: Size,
slot: Size,
foreground: [3]u8 = @splat(255),
