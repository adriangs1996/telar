//! Reads the wall clock in the user's time zone for bar callbacks.
const builtin = @import("builtin");
const std = @import("std");
const data = @import("model");
const LocalTime = data.LocalTime;

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

const epoch = LocalTime.epoch;

/// Example: `const local = local_time.now();`
pub fn now() LocalTime {
    if (builtin.os.tag == .windows) {
        return windowsNow();
    }

    return posixNow();
}

/// Minutes east of UTC in the user's time zone right now; zero when the
/// clock or the zone is unreadable. Derived by comparing the local and the
/// UTC calendar fields, so it needs no platform-specific `tm` member.
/// Example: `const offset = local_time.utcOffsetMinutes();`
pub fn utcOffsetMinutes() i16 {
    if (builtin.os.tag == .windows) {
        return 0;
    }

    var seconds: time.time_t = 0;
    if (time.time(&seconds) == -1) {
        return 0;
    }

    var local: time.struct_tm = undefined;
    var utc: time.struct_tm = undefined;
    if (time.localtime_r(&seconds, &local) == null or time.gmtime_r(&seconds, &utc) == null) {
        return 0;
    }

    const day_delta: i32 = if (local.tm_year != utc.tm_year)
        (if (local.tm_year > utc.tm_year) 1 else -1)
    else
        local.tm_yday - utc.tm_yday;
    const minutes = day_delta * 24 * 60 + (local.tm_hour - utc.tm_hour) * 60 + (local.tm_min - utc.tm_min);
    return @intCast(std.math.clamp(minutes, -14 * 60, 14 * 60));
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

test "the UTC offset stays inside the range time zones use" {
    const offset = utcOffsetMinutes();

    try std.testing.expect(offset >= -14 * 60 and offset <= 14 * 60);
}

test "the local clock reports a calendar date" {
    const local = now();

    try std.testing.expect(local.month >= 1 and local.month <= 12);
    try std.testing.expect(local.day >= 1 and local.day <= 31);
    try std.testing.expect(local.weekday <= 6);
}
