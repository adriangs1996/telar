const Package = @import("Package.zig");
const Installation = @This();

package: *const Package,
destination: []const u8,
