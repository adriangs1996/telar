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

pub fn setRow(self: *Builder, y: u16, flags: RowFlags) void {
    std.debug.assert(y < self.rows);
    self.buffer[limits.header_size + @as(usize, y)] = @bitCast(flags);
}

/// URI identities are assigned by the VT adapter, not inferred from their text.
/// Example: `const index = try builder.addLink(uri);`
pub fn addLink(self: *Builder, uri: []const u8) !u16 {
    if (uri.len == 0 or uri.len > limits.max_uri_bytes or self.link_count == limits.max_links or uri.len > limits.max_total_uri_bytes - self.uri_len) {
        return error.TextMetadataQuotaExceeded;
    }

    const index = self.link_count;
    const offset = limits.header_size + @as(usize, self.rows) + @as(usize, index) * limits.link_size;
    std.mem.writeInt(u32, self.buffer[offset..][0..4], self.uri_len, .little);
    std.mem.writeInt(u16, self.buffer[offset + 4 ..][0..2], @intCast(uri.len), .little);
    const uri_start = self.uriStart() + self.uri_len;
    @memcpy(self.buffer[uri_start..][0..uri.len], uri);
    self.uri_len += @intCast(uri.len);
    self.link_count += 1;
    return index;
}

/// Adds a sorted, row-local interval. Example: `try builder.addRun(run);`
pub fn addRun(self: *Builder, run: LinkRun) !void {
    if (self.run_count == limits.max_runs) {
        return error.TextMetadataQuotaExceeded;
    }

    const offset = self.runStart() + @as(usize, self.run_count) * limits.run_size;
    std.mem.writeInt(u32, self.buffer[offset..][0..4], run.start, .little);
    std.mem.writeInt(u32, self.buffer[offset + 4 ..][0..4], run.len, .little);
    std.mem.writeInt(u16, self.buffer[offset + 8 ..][0..2], run.link_index, .little);
    self.run_count += 1;
}

/// Compacts the replacement; quota failure keeps row semantics and clears every link.
/// Example: `const view = builder.finish(.complete);`
pub fn finish(self: *Builder, status: limits.Status) View {
    if (status == .omitted) {
        self.link_count = 0;
        self.run_count = 0;
        self.uri_len = 0;
    }

    const runs_start = limits.header_size + @as(usize, self.rows) + @as(usize, self.link_count) * limits.link_size;
    const run_bytes = @as(usize, self.run_count) * limits.run_size;
    std.mem.copyForwards(u8, self.buffer[runs_start..][0..run_bytes], self.buffer[self.runStart()..][0..run_bytes]);
    const uris_start = runs_start + run_bytes;
    std.mem.copyForwards(u8, self.buffer[uris_start..][0..self.uri_len], self.buffer[self.uriStart()..][0..self.uri_len]);
    self.buffer[0] = @intFromEnum(status);
    std.mem.writeInt(u16, self.buffer[1..3], self.rows, .little);
    std.mem.writeInt(u16, self.buffer[3..5], self.link_count, .little);
    std.mem.writeInt(u16, self.buffer[5..7], self.run_count, .little);
    std.mem.writeInt(u32, self.buffer[7..11], self.uri_len, .little);
    return View.trusted(self.buffer[0 .. uris_start + self.uri_len]);
}

fn runStart(self: *const Builder) usize {
    return limits.header_size + @as(usize, self.rows) + limits.max_links * limits.link_size;
}

fn uriStart(self: *const Builder) usize {
    return self.runStart() + limits.max_runs * limits.run_size;
}
