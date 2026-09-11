const std = @import("std");

pub const SYSTEMTIME = extern struct {
    year: std.os.windows.WORD,
    month: std.os.windows.WORD,
    day_of_week: std.os.windows.WORD,
    day: std.os.windows.WORD,
    hour: std.os.windows.WORD,
    minute: std.os.windows.WORD,
    second: std.os.windows.WORD,
    milliseconds: std.os.windows.WORD,
};
