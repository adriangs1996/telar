const std = @import("std");
const Mapping = @This();

placeholder: [*]const u8,
pixels: []align(std.heap.page_size_min) u8,
