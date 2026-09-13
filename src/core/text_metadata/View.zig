//! Validated, borrowed metadata. URI and run storage share the frame lifetime.
const std = @import("std");
const limits = @import("limits.zig");
const RowFlags = @import("RowFlags.zig").RowFlags;
const LinkRun = @import("LinkRun.zig");
const Runs = @import("Runs.zig");
const Decoder = @import("../schema/Decoder.zig");
const View = @This();

encoded: []const u8,
status: limits.Status,
rows: []const RowFlags,
link_count: u16,
run_count: u16,
link_bytes: []const u8,
run_bytes: []const u8,
uri_bytes: []const u8,

/// Validates every offset before a frame can mutate client storage.
/// Example: `const view = try View.decode(bytes, .{ cols, rows });`
pub fn decode(bytes: []const u8, size: [2]u16) !View {
    if (bytes.len > limits.capacity(size[1])) {
        return error.TextMetadataTooLarge;
    }

    var reader = Decoder.init(bytes);
    const status = std.enums.fromInt(limits.Status, try reader.readByte()) orelse return error.InvalidTextMetadata;
    const row_count = try reader.readInt(u16);
    const link_count = try reader.readInt(u16);
    const run_count = try reader.readInt(u16);
    const uri_length = try reader.readInt(u32);
    if (row_count != size[1] or link_count > limits.max_links or run_count > limits.max_runs or uri_length > limits.max_total_uri_bytes) {
        return error.InvalidTextMetadata;
    }

    if (status == .omitted and (link_count != 0 or run_count != 0 or uri_length != 0)) {
        return error.InvalidTextMetadata;
    }

    const rows = try reader.readBytes(row_count);
    for (rows) |flags| {
        if (flags & 0xf0 != 0 or (flags & 4 != 0 and (flags & 1 == 0 or size[0] < 2))) {
            return error.InvalidTextMetadata;
        }
    }

    const links = try reader.readBytes(@as(usize, link_count) * limits.link_size);
    const run_bytes = try reader.readBytes(@as(usize, run_count) * limits.run_size);
    const uris = try reader.readBytes(uri_length);
    try reader.ensureEnd();
    var uri_end: usize = 0;
    var link_reader = Decoder.init(links);
    for (0..link_count) |_| {
        const offset = try link_reader.readInt(u32);
        const len = try link_reader.readInt(u16);
        if (offset != uri_end or len == 0 or len > limits.max_uri_bytes or len > uris.len - uri_end) {
            return error.InvalidTextMetadata;
        }

        uri_end += len;
    }

    if (uri_end != uris.len) {
        return error.InvalidTextMetadata;
    }

    var iterator: Runs = .{ .bytes = run_bytes };
    var previous_end: u32 = 0;
    const cell_count = @as(u32, size[0]) * size[1];
    while (iterator.next()) |run| {
        const end = std.math.add(u32, run.start, run.len) catch return error.InvalidTextMetadata;
        if (run.len == 0 or run.start < previous_end or end > cell_count or run.link_index >= link_count or size[0] == 0) {
            return error.InvalidTextMetadata;
        }

        if (run.start / size[0] != (end - 1) / size[0]) {
            return error.InvalidTextMetadata;
        }

        previous_end = end;
    }

    return trusted(bytes);
}

/// Views bytes already admitted by decode or produced by the metadata builder.
/// Example: `const view = View.trusted(storage.bytes());`
pub fn trusted(bytes: []const u8) View {
    const row_count = std.mem.readInt(u16, bytes[1..3], .little);
    const link_count = std.mem.readInt(u16, bytes[3..5], .little);
    const run_count = std.mem.readInt(u16, bytes[5..7], .little);
    const links_start = limits.header_size + @as(usize, row_count);
    const runs_start = links_start + @as(usize, link_count) * limits.link_size;
    const uris_start = runs_start + @as(usize, run_count) * limits.run_size;
    return .{
        .encoded = bytes,
        .status = @enumFromInt(bytes[0]),
        .rows = @as([*]const RowFlags, @ptrCast(bytes[limits.header_size..].ptr))[0..row_count],
        .link_count = link_count,
        .run_count = run_count,
        .link_bytes = bytes[links_start..runs_start],
        .run_bytes = bytes[runs_start..uris_start],
        .uri_bytes = bytes[uris_start..],
    };
}

/// Returns the full URI for a snapshot-local hyperlink identity.
/// Example: `const uri = view.link(run.link_index).?;`
pub fn link(view: View, index: u16) ?[]const u8 {
    if (index >= view.link_count) {
        return null;
    }

    const bytes = view.link_bytes[@as(usize, index) * limits.link_size ..];
    const offset = std.mem.readInt(u32, bytes[0..4], .little);
    const len = std.mem.readInt(u16, bytes[4..6], .little);
    return view.uri_bytes[offset..][0..len];
}

pub fn runs(view: View) Runs {
    return .{ .bytes = view.run_bytes };
}

/// Finds the run covering a linear cell index without scanning the viewport.
/// Example: `const run = view.at(@as(u32, y) * cols + x);`
pub fn at(view: View, cell: u32) ?LinkRun {
    var low: usize = 0;
    var high: usize = view.run_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        var iterator: Runs = .{ .bytes = view.run_bytes[mid * limits.run_size ..] };
        const run = iterator.next().?;
        if (cell < run.start) {
            high = mid;
        } else if (cell >= run.start + run.len) {
            low = mid + 1;
        } else {
            return run;
        }
    }

    return null;
}
