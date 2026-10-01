//! Formats the clock component from the client's local time, so a clock in
//! the bar needs no Lua callback and no tick of its own.
const BarLayout = @import("BarLayout.zig");
const LocalTime = @import("../state/LocalTime.zig");
const bar_values = @import("model.zig");
const std = @import("std");

const seconds_per_minute: u64 = 60;

pub const max_format_bytes = 32;
/// A directive is `%` and one letter.
const directive_bytes = 2;
/// Room for the longest expansion of `max_format_bytes` of directives:
/// each writes at most the longest month or weekday name, so no clock is
/// ever cut.
pub const max_output_bytes = max_format_bytes / directive_bytes * longestName();

const noon: u8 = 12;
const century: u16 = 100;
const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// Expands a strftime subset into `buffer`: `%H %M %S %I %p %d %e %m %y %Y
/// %a %A %b %B %%`. Any other byte, and an unknown directive, is copied.
///
/// ```zig
/// var buffer: [bar_clock.max_output_bytes]u8 = undefined;
/// const text = bar_clock.format(&buffer, "%H:%M %d/%m", now); // "11:52 26/09"
/// ```
pub fn format(buffer: *[max_output_bytes]u8, pattern: []const u8, time: LocalTime) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte != '%' or index + 1 == pattern.len) {
            writer.writeByte(byte) catch break;
            continue;
        }

        index += 1;
        writeDirective(&writer, pattern[index], time) catch break;
    }

    return writer.buffered();
}

/// Whether the pattern changes every second rather than every minute.
/// Example: `const period = if (bar_clock.showsSeconds(format)) second else minute;`
pub fn showsSeconds(pattern: []const u8) bool {
    return std.mem.indexOf(u8, pattern, "%S") != null;
}

/// How often the clocks of a bar layout change.
pub const Period = enum {
    second,
    minute,
};

/// The shortest period of the clock components a layout shows, or null
/// when it shows none, so the client arms no clock tick at all.
/// Example: `const period = bar_clock.period(&model.bars.layout) orelse return;`
pub fn period(layout: *const BarLayout) ?Period {
    var result: ?Period = null;
    for (std.enums.values(bar_values.Position)) |position| {
        const content = layout.content(position) orelse continue;
        for (content.slice()) |node| {
            if (node.kind != .clock) {
                continue;
            }
            if (showsSeconds(content.text(node.text))) {
                return .second;
            }

            result = .minute;
        }
    }

    return result;
}

/// Nanoseconds from `time` to the next change of a clock of this period.
/// Example: `const wait_ns = bar_clock.untilNext(.minute, now); // at 11:52:40, 20 s`
pub fn untilNext(clock_period: Period, time: LocalTime) u64 {
    return switch (clock_period) {
        .second => std.time.ns_per_s,
        .minute => @as(u64, seconds_per_minute - @min(time.second, seconds_per_minute - 1)) * std.time.ns_per_s,
    };
}

fn writeDirective(writer: *std.Io.Writer, directive: u8, time: LocalTime) !void {
    switch (directive) {
        'H' => try writer.print("{d:0>2}", .{time.hour}),
        'M' => try writer.print("{d:0>2}", .{time.minute}),
        'S' => try writer.print("{d:0>2}", .{time.second}),
        'I' => try writer.print("{d:0>2}", .{twelveHour(time.hour)}),
        'p' => try writer.writeAll(if (time.hour < noon) "AM" else "PM"),
        'd' => try writer.print("{d:0>2}", .{time.day}),
        'e' => try writer.print("{d}", .{time.day}),
        'm' => try writer.print("{d:0>2}", .{time.month}),
        'y' => try writer.print("{d:0>2}", .{time.year % century}),
        'Y' => try writer.print("{d}", .{time.year}),
        'a' => try writer.writeAll(named(&weekdays, time.weekday)),
        'A' => try writer.writeAll(named(&weekday_names, time.weekday)),
        'b' => try writer.writeAll(named(&months, time.month -| 1)),
        'B' => try writer.writeAll(named(&month_names, time.month -| 1)),
        '%' => try writer.writeByte('%'),
        else => {
            try writer.writeByte('%');
            try writer.writeByte(directive);
        },
    }
}

fn twelveHour(hour: u8) u8 {
    const value = hour % noon;
    return if (value == 0) noon else value;
}

fn named(names: []const []const u8, index: usize) []const u8 {
    return names[@min(index, names.len - 1)];
}

test "clock formats the strftime subset from local time" {
    const time: LocalTime = .{
        .year = 2026,
        .month = 9,
        .day = 6,
        .hour = 13,
        .minute = 5,
        .second = 9,
        .weekday = 6,
    };
    var buffer: [max_output_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("13:05 06/09", format(&buffer, "%H:%M %d/%m", time));
    try std.testing.expectEqualStrings("Sat 6 Sep 26, 01 PM", format(&buffer, "%a %e %b %y, %I %p", time));
    try std.testing.expectEqualStrings("100% %q", format(&buffer, "100%% %q", time));
    try std.testing.expect(showsSeconds("%H:%M:%S"));
    try std.testing.expect(!showsSeconds("%H:%M"));
}

fn longestName() usize {
    var longest: usize = 0;
    for (weekday_names ++ month_names) |name| {
        longest = @max(longest, name.len);
    }

    return longest;
}

test "a format of the longest directives fits the output whole" {
    var buffer: [max_output_bytes]u8 = undefined;
    const time: LocalTime = .{
        .year = 2026,
        .month = 9,
        .day = 30,
        .hour = 11,
        .minute = 52,
        .second = 0,
        .weekday = 3,
    };

    const text = format(&buffer, "%B" ** (max_format_bytes / directive_bytes), time);
    try std.testing.expectEqualStrings("September" ** (max_format_bytes / directive_bytes), text);
}
