const std = @import("std");
const COORD = @import("Coord.zig").COORD;
const SMALL_RECT = @import("SmallRect.zig").SMALL_RECT;

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: std.os.windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
