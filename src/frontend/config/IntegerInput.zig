const IntegerBounds = @import("IntegerBounds.zig");
const IntegerInput = @This();

table: c_int,
field: [:0]const u8,
label: []const u8,
bounds: IntegerBounds,
