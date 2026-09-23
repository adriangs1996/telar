const IntegerInput = @This();

table: c_int,
field: [:0]const u8,
label: []const u8,
bounds: IntegerBounds,

const IntegerBounds = struct {
    default: u32,
    min: u32,
    max: u32,
};
