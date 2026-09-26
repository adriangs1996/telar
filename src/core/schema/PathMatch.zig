const types = @import("types.zig");
/// One path the picker found: relative to the requested root, directories
/// ending in `/`, and the byte offset of every query byte in `path`.
const PathMatch = @This();

path: []const u8,
kind: types.PathKind,
positions: []const u16 = &.{},
