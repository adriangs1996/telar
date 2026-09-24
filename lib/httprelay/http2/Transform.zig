const Rewrite = @import("../Rewrite.zig");
/// The rewrites one direction applies to its heads.
const Transform = @This();

rewrites: []const Rewrite,
