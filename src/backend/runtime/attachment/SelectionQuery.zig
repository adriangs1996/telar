const Range = @import("Range.zig");
const SelectionQuery = @This();

range: Range,
scratch: []u8,
