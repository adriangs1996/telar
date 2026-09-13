//! Fixed scratch space for a complete viewport replacement.
const std = @import("std");
const limits = @import("limits.zig");
const View = @import("View.zig");
const LinkRun = @import("LinkRun.zig");
const RowFlags = @import("RowFlags.zig").RowFlags;
const Builder = @This();

buffer: []u8,
rows: u16,
link_count: u16 = 0,
run_count: u16 = 0,
uri_len: u32 = 0,

/// Borrows capacity reserved outside frame processing.
/// Example: `var builder = Builder.init(scratch, rows);`
pub fn init(buffer: []u8, rows: u16) Builder {
    std.debug.assert(buffer.len >= limits.capacity(rows));
    @memset(buffer[0 .. limits.header_size + @as(usize, rows)], 0);
    return .{ .buffer = buffer, .rows = rows };
}

pub fn setRow(builder: *Builder, y: u16, flags: RowFlags) void {
    std.debug.assert(y < builder.rows);
    builder.buffer[limits.header_size + @as(usize, y)] = @bitCast(flags);
}

/// URI identities are assigned by the VT adapter, not inferred from their text.
/// Example: `const index = try builder.addLink(uri);`
pub fn addLink(builder: *Builder, uri: []const u8) !u16 {
    if (uri.len == 0 or uri.len > limits.max_uri_bytes or builder.link_count == limits.max_links or uri.len > limits.max_total_uri_bytes - builder.uri_len) {
        return error.TextMetadataQuotaExceeded;
    }

    const index = builder.link_count;
    const offset = limits.header_size + @as(usize, builder.rows) + @as(usize, index) * limits.link_size;
    std.mem.writeInt(u32, builder.buffer[offset..][0..4], builder.uri_len, .little);
    std.mem.writeInt(u16, builder.buffer[offset + 4 ..][0..2], @intCast(uri.len), .little);
    const uri_start = builder.uriStart() + builder.uri_len;
    @memcpy(builder.buffer[uri_start..][0..uri.len], uri);
    builder.uri_len += @intCast(uri.len);
    builder.link_count += 1;
    return index;
}

/// Adds a sorted, row-local interval. Example: `try builder.addRun(run);`
pub fn addRun(builder: *Builder, run: LinkRun) !void {
    if (builder.run_count == limits.max_runs) {
        return error.TextMetadataQuotaExceeded;
    }

    const offset = builder.runStart() + @as(usize, builder.run_count) * limits.run_size;
    std.mem.writeInt(u32, builder.buffer[offset..][0..4], run.start, .little);
    std.mem.writeInt(u32, builder.buffer[offset + 4 ..][0..4], run.len, .little);
    std.mem.writeInt(u16, builder.buffer[offset + 8 ..][0..2], run.link_index, .little);
    builder.run_count += 1;
}

/// Compacts the replacement; quota failure keeps row semantics and clears every link.
/// Example: `const view = builder.finish(.complete);`
pub fn finish(builder: *Builder, status: limits.Status) View {
    if (status == .omitted) {
        builder.link_count = 0;
        builder.run_count = 0;
        builder.uri_len = 0;
    }

    const runs_start = limits.header_size + @as(usize, builder.rows) + @as(usize, builder.link_count) * limits.link_size;
    const run_bytes = @as(usize, builder.run_count) * limits.run_size;
    std.mem.copyForwards(u8, builder.buffer[runs_start..][0..run_bytes], builder.buffer[builder.runStart()..][0..run_bytes]);
    const uris_start = runs_start + run_bytes;
    std.mem.copyForwards(u8, builder.buffer[uris_start..][0..builder.uri_len], builder.buffer[builder.uriStart()..][0..builder.uri_len]);
    builder.buffer[0] = @intFromEnum(status);
    std.mem.writeInt(u16, builder.buffer[1..3], builder.rows, .little);
    std.mem.writeInt(u16, builder.buffer[3..5], builder.link_count, .little);
    std.mem.writeInt(u16, builder.buffer[5..7], builder.run_count, .little);
    std.mem.writeInt(u32, builder.buffer[7..11], builder.uri_len, .little);
    return View.trusted(builder.buffer[0 .. uris_start + builder.uri_len]);
}

fn runStart(builder: *const Builder) usize {
    return limits.header_size + @as(usize, builder.rows) + limits.max_links * limits.link_size;
}

fn uriStart(builder: *const Builder) usize {
    return builder.runStart() + limits.max_runs * limits.run_size;
}
