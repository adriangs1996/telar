const quad = @import("../../render/Quad.zig");

id: u64,
/// Must change whenever ANY quad byte changes, including visual invalidation.
revision: u64,
quads: []const quad.Quad,
