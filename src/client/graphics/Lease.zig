const ImageIdentityType = @import("ImageIdentity.zig");
const Lease = @This();

identity: ImageIdentityType,
pixels: []const u8
