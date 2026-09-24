//! The shape of a synthetic PNG the decoder tests encode, including the
//! header fields a real encoder would never emit.
const PngHeader = @import("PngHeader.zig");

header: PngHeader,
filter: u8 = 0,
interlace: u8 = 0,
depth: ?u8 = null,
palette: []const u8 = &.{},
transparency: []const u8 = &.{},
