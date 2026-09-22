//! Explicit native-terminal colors; the TUI retains its host's terminal palette.
const std = @import("std");
foreground: [3]u8 = .{ 229, 229, 229 },
background: [3]u8 = .{ 24, 24, 27 },
cursor_color: ?[3]u8 = null,
cursor_text_color: ?[3]u8 = null,
palette: [16][3]u8 = .{
    .{ 0, 0, 0 },       .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 229, 16 },
    .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
    .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
    .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
},

/// Cursor-only edits reuse retained cell ink. Example: `theme.sameCells(previous)`.
pub fn sameCells(theme: @This(), previous: @This()) bool {
    return std.meta.eql(theme.foreground, previous.foreground) and
        std.meta.eql(theme.background, previous.background) and
        std.meta.eql(theme.palette, previous.palette);
}
