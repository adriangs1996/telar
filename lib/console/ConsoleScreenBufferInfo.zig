const Coord = @import("Coord.zig");
const SmallRect = @import("SmallRect.zig");
const std = @import("std");

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: Coord.COORD,
    dwCursorPosition: Coord.COORD,
    wAttributes: std.os.windows.WORD,
    srWindow: SmallRect.SMALL_RECT,
    dwMaximumWindowSize: Coord.COORD,
};
