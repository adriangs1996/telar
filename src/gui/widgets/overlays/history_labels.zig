const std = @import("std");
const core = @import("telar-core");

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
    var right: core.GraphemeIterator = .{ .bytes = text };
    var left = right;
    var bytes: usize = 0;
    var codepoints: usize = 0;
    while (right.next()) |cluster| {
        bytes += cluster.bytes.len;
        codepoints += std.unicode.utf8CountCodepoints(cluster.bytes) catch unreachable;
        while (bytes > limits.bytes or codepoints > limits.codepoints) {
            const first = left.next().?;
            bytes -= first.bytes.len;
            codepoints -= std.unicode.utf8CountCodepoints(first.bytes) catch unreachable;
        }
    }

    return left.index;
}

fn copyPath(path: []const u8, destination: []u8) []const u8 {
    var iterator: core.GraphemeIterator = .{ .bytes = path };
    var written: usize = 0;
    while (iterator.next()) |cluster| {
        @memcpy(destination[written..][0..cluster.bytes.len], cluster.bytes);
        written += cluster.bytes.len;
    }

    return destination[0..written];
}

test "compact history paths preserve components and bounded valid graphemes" {
    var storage: [path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/work/telar", compactPath("/work/telar", &storage));
    try std.testing.expectEqualStrings("…/sandbox/telar", compactPath("/Users/adriangonzalez/sandbox/telar", &storage));
    try std.testing.expectEqualStrings("/", compactPath("/" ** 80, &storage));
    const unicode_path = "/work/" ++ "e\u{301}" ** 40;
    const unicode_tail = compactPath(unicode_path, &storage);
    try std.testing.expectEqualStrings("…/" ++ "e\u{301}" ** 14, unicode_tail);
    const paths = [_][]const u8{ "/work/" ++ "界" ** 40, "/work/" ++ "\u{1f600}" ** 40, "/work/" ++ "a" ** 100, "/work/\xff\x1b" };
    for (paths) |path| {
        const result = compactPath(path, &storage);
        try std.testing.expect(result.len <= path_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result));
        try std.testing.expect((try std.unicode.utf8CountCodepoints(result)) <= 30);
    }
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
