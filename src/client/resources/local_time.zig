//! Reads the wall clock in the user's time zone for bar callbacks.
const builtin = @import("builtin");
const std = @import("std");
const LocalTime = @import("LocalTime.zig");

const time = @cImport({
    @cInclude("time.h");
});

const SystemTime = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};

extern "kernel32" fn GetLocalTime(system_time: *SystemTime) callconv(.winapi) void;

/// The Unix epoch, reported when the clock or the time zone is unreadable.
const epoch: LocalTime = .{
    .year = 1970,
    .month = 1,
    .day = 1,
    .hour = 0,
    .minute = 0,
    .second = 0,
    .weekday = 4,
};

/// Example: `const local = local_time.now();`
pub fn now() LocalTime {
    if (builtin.os.tag == .windows) {
        return windowsNow();
    }

    return posixNow();
}

fn posixNow() LocalTime {
    var seconds: time.time_t = 0;
    if (time.time(&seconds) == -1) {
        return epoch;
    }

    var local: time.struct_tm = undefined;
    if (time.localtime_r(&seconds, &local) == null) {
        return epoch;
    }

    return .{
        .year = @intCast(local.tm_year + 1900),
        .month = @intCast(local.tm_mon + 1),
        .day = @intCast(local.tm_mday),
        .hour = @intCast(local.tm_hour),
        .minute = @intCast(local.tm_min),
        .second = @intCast(local.tm_sec),
        .weekday = @intCast(local.tm_wday),
    };
}

fn windowsNow() LocalTime {
    var value: SystemTime = undefined;
    GetLocalTime(&value);

    return .{
        .year = value.year,
        .month = @intCast(value.month),
        .day = @intCast(value.day),
        .hour = @intCast(value.hour),
        .minute = @intCast(value.minute),
        .second = @intCast(value.second),
        .weekday = @intCast(value.day_of_week),
    };
}

test "Windows SYSTEMTIME keeps its ABI" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SystemTime));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(SystemTime, "milliseconds"));
}

test "the local clock reports a calendar date" {
    const local = now();

    try std.testing.expect(local.month >= 1 and local.month <= 12);
    try std.testing.expect(local.day >= 1 and local.day <= 31);
    try std.testing.expect(local.weekday <= 6);
}
