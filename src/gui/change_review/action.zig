const std = @import("std");

pub const Kind = enum(u32) { background = 1, file, previous, next, line, line_comment, code, comment, save, fold, edit, delete, editor, simulate, version, reviewed, theme, open_comment, submit, close, previous_edition, next_edition, refresh, search };

pub fn encode(action_kind: Kind, index: usize) u64 {
    return (@as(u64, @intFromEnum(action_kind)) << 32) | @as(u32, @intCast(index));
}

pub fn kind(value: u64) ?Kind {
    return std.enums.fromInt(Kind, @as(u32, @intCast(value >> 32)));
}

pub fn item(value: u64) usize {
    return @as(u32, @truncate(value));
}
