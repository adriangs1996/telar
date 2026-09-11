const Installation = @This();
const Package = @import("Package.zig");
package: *const Package,
destination: []const u8,
