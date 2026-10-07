const cellgrid = @import("cellgrid");
const std = @import("std");

pub const path_bytes = 61;

/// Keeps the last complete path components inside one cached shaping run.
/// Long basenames retain a grapheme-safe suffix; the inspector keeps the full
/// path. Example: `const label = compactPath(entry.cwdSlice(), &storage);`
pub fn compactPath(path: []const u8, storage: *[path_bytes]u8) []const u8 {
    if (path.len <= path_bytes and tailStart(path, .{ .bytes = path_bytes, .codepoints = 30 }) == 0) {
        return copyPath(path, storage);
    }

    const end = std.mem.trimEnd(u8, path, "/").len;
    if (end == 0) {
        return "/";
    }

    const leaf = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |index| index + 1 else 0;
    const parent = if (std.mem.lastIndexOfScalar(u8, path[0..leaf -| 1], '/')) |index| index + 1 else 0;
    const candidate = path[parent..end];
    const prefix = "…/";
    var start = tailStart(candidate, .{ .bytes = path_bytes - prefix.len, .codepoints = 28 });
    if (start != 0) {
        if (std.mem.indexOfScalar(u8, candidate[start..], '/')) |separator| {
            start += separator + 1;
        }
    }

    @memcpy(storage[0..prefix.len], prefix);
    const tail = copyPath(candidate[start..], storage[prefix.len..]);
    return storage[0 .. prefix.len + tail.len];
}

fn tailStart(text: []const u8, limits: struct { bytes: usize, codepoints: usize }) usize {
    var right: cellgrid.GraphemeIterator = .{ .bytes = text };
    var left = right;
    var bytes: usize = 0;
    var codepoints: usize = 0;
    while (right.next()) |cluster| {
        bytes += cluster.bytes.len;
        // SAFETY: GraphemeIterator returns valid UTF-8 clusters, replacing invalid input with U+FFFD.
        codepoints += std.unicode.utf8CountCodepoints(cluster.bytes) catch unreachable;
        while (bytes > limits.bytes or codepoints > limits.codepoints) {
            const first = left.next().?;
            bytes -= first.bytes.len;
            // SAFETY: the left GraphemeIterator has the same valid-cluster guarantee as the right iterator.
            codepoints -= std.unicode.utf8CountCodepoints(first.bytes) catch unreachable;
        }
    }

    return left.index;
}

fn copyPath(path: []const u8, destination: []u8) []const u8 {
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = path };
    var written: usize = 0;
    while (iterator.next()) |cluster| {
        @memcpy(destination[written..][0..cluster.bytes.len], cluster.bytes);
        written += cluster.bytes.len;
    }

    return destination[0..written];
}

/// Fits the native history duration column without losing its unit.
/// Example: `const label = duration(entry.duration_ns, &storage);`.
pub fn duration(ns: i64, storage: []u8) []const u8 {
    const milliseconds = @divTrunc(@max(ns, 0), std.time.ns_per_ms);
    return if (milliseconds < 1000)
        std.fmt.bufPrint(storage, "{d}ms", .{milliseconds}) catch "?"
    else if (milliseconds < 60000)
        std.fmt.bufPrint(storage, "{d}.{d}s", .{ @divTrunc(milliseconds, 1000), @divTrunc(@mod(milliseconds, 1000), 100) }) catch "?"
    else if (milliseconds < 3600000)
        std.fmt.bufPrint(storage, "{d}m", .{@divTrunc(milliseconds, 60000)}) catch "?"
    else
        std.fmt.bufPrint(storage, "{d}h", .{@divTrunc(milliseconds, 3600000)}) catch "?";
}

/// Formats the age from the query's owned timestamp, requiring no clock read.
/// Example: `const label = age(state.now_ms -| entry.started_at_ms, &storage);`.
pub fn age(ms: i64, storage: []u8) []const u8 {
    const seconds = @divTrunc(@max(ms, 0), 1000);
    return if (seconds < 60)
        "now"
    else if (seconds < 3600)
        std.fmt.bufPrint(storage, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "?"
    else if (seconds < 86400)
        std.fmt.bufPrint(storage, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "?"
    else
        std.fmt.bufPrint(storage, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "?";
}

const seconds_per_day: i64 = 86400;
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const short_weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// The calendar day a timestamp falls on in the zone `offset_min` describes,
/// counted from 1970-01-01. Two entries share a day group when they share it.
/// Example: `const today = localDay(history.now_ms, history.utc_offset_min);`.
pub fn localDay(ms: i64, offset_min: i16) i64 {
    return @divFloor(@divFloor(ms, std.time.ms_per_s) + @as(i64, offset_min) * 60, seconds_per_day);
}

/// Wall-clock time of a timestamp in the local zone.
/// Example: `const label = clock(entry.started_at_ms, history.utc_offset_min, &storage);`.
pub fn clock(ms: i64, offset_min: i16, storage: []u8) []const u8 {
    const seconds: u32 = @intCast(@mod(@divFloor(ms, std.time.ms_per_s) + @as(i64, offset_min) * 60, seconds_per_day));
    return std.fmt.bufPrint(storage, "{d:0>2}:{d:0>2}", .{ seconds / 3600, (seconds % 3600) / 60 }) catch "?";
}

/// The heading of one day group: today and yesterday by name, the rest of
/// the week by weekday, this year by month and day, older by month and year.
/// Example: `const heading = dayLabel(day, today, &storage);`.
pub fn dayLabel(day: i64, today: i64, storage: []u8) []const u8 {
    const distance = today - day;
    if (distance == 0) {
        return "Today";
    }
    if (distance == 1) {
        return "Yesterday";
    }
    if (distance > 1 and distance < 7) {
        return weekday_names[weekday(day)];
    }

    const date = calendar(day) orelse return "Earlier";
    if (calendar(today)) |now| {
        if (now.year == date.year) {
            return std.fmt.bufPrint(storage, "{s} {d}", .{ month_names[date.month - 1], date.day }) catch "?";
        }
    }

    return std.fmt.bufPrint(storage, "{s} {d}", .{ month_names[date.month - 1], date.year }) catch "?";
}

/// The time column of a searched row, which has no day group above it:
/// the clock today, the day this week, the date this year, the year before.
/// Example: `const label = dateLabel(entry.started_at_ms, history.now_ms, history.utc_offset_min, &storage);`.
pub fn dateLabel(ms: i64, now_ms: i64, offset_min: i16, storage: []u8) []const u8 {
    const day = localDay(ms, offset_min);
    const today = localDay(now_ms, offset_min);
    const distance = today - day;
    if (distance == 0) {
        return clock(ms, offset_min, storage);
    }
    if (distance == 1) {
        return "Yesterday";
    }
    if (distance > 1 and distance < 7) {
        return short_weekday_names[weekday(day)];
    }

    const date = calendar(day) orelse return "Earlier";
    if (calendar(today)) |now| {
        if (now.year == date.year) {
            return std.fmt.bufPrint(storage, "{s} {d}", .{ month_names[date.month - 1], date.day }) catch "?";
        }
    }

    return std.fmt.bufPrint(storage, "{d}", .{date.year}) catch "?";
}

// 1970-01-01 was a Thursday; Sunday is 0.
fn weekday(day: i64) usize {
    return @intCast(@mod(day + 4, 7));
}

const CalendarDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

fn calendar(day: i64) ?CalendarDate {
    if (day < 0 or day > 2932896) {
        return null;
    }

    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
    };
}
