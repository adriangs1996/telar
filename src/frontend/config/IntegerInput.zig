const IntegerInput = @This();
const IntegerBounds = @import("IntegerBounds.zig");
table: c_int,
field: [:0]const u8,
label: []const u8,
bounds: IntegerBounds,
