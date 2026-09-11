const RowTarget = @import("RowTarget.zig");
const std = @import("std");
const vt = @import("ghostty-vt");
const ColorSource = @import("ColorSource.zig");
const RowProjection = @This();

target: RowTarget,
cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
colors: ColorSource,
