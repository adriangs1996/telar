const std = @import("std");
const Reservation = @import("Reservation.zig");
const Pane = @import("Pane.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const Key = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const Buffer = @import("Buffer.zig");
const HalfOptions = @import("HalfOptions.zig");
const Half = @This();

gpa: std.mem.Allocator,
reservation: Reservation,
pane: Pane,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
key: Key,
side: buffer_support.Side,
head: Buffer,
body: Buffer,
host_storage: [buffer_support.max_host_bytes]u8 = undefined,
host_len: u16 = 0,
method_storage: [buffer_support.max_method_bytes]u8 = undefined,
method_len: u8 = 0,
target_storage: [buffer_support.max_target_bytes]u8 = undefined,
target_len: u16 = 0,
encoding_storage: [buffer_support.max_encoding_bytes]u8 = undefined,
encoding_len: u8 = 0,
status_code: u16 = 0,
started_at_ms: i64,
finished_at_ms: i64 = 0,
outcome: buffer_support.Outcome = .failed,
captured_bytes: usize = 0,
body_decoded: bool = false,

pub fn create(options: HalfOptions) ?*Half {
    if (!options.config.enabled) {
        return null;
    }

    const reservation_bytes = @max(@as(usize, 1), options.config.max_exchange_bytes / 2);
    var reservation = options.quota.reserve(reservation_bytes) orelse return null;

    if (options.host.len > buffer_support.max_host_bytes) {
        reservation.release();
        return null;
    }

    const half = options.gpa.create(Half) catch {
        reservation.release();
        return null;
    };
    half.* = .{
        .gpa = options.gpa,
        .reservation = reservation,
        .pane = .{ .id = options.credential.pane_id, .generation = options.credential.pane_generation },
        .dialect = options.dialect,
        .protocol = options.protocol,
        .key = options.key,
        .side = options.side,
        .head = .init(options.gpa, options.config.max_part_bytes),
        .body = .init(options.gpa, options.config.max_part_bytes),
        .started_at_ms = options.started_at_ms,
    };
    @memcpy(half.host_storage[0..options.host.len], options.host);
    half.host_len = @intCast(options.host.len);

    return half;
}

pub fn host(half: *const Half) []const u8 {
    return half.host_storage[0..half.host_len];
}

pub fn method(half: *const Half) []const u8 {
    return half.method_storage[0..half.method_len];
}

pub fn target(half: *const Half) []const u8 {
    return half.target_storage[0..half.target_len];
}

pub fn encoding(half: *const Half) []const u8 {
    return half.encoding_storage[0..half.encoding_len];
}

pub fn setRoute(half: *Half, method_value: []const u8, target_value: []const u8) void {
    if (method_value.len > half.method_storage.len or target_value.len > half.target_storage.len) {
        half.head.truncated = true;
        return;
    }

    @memcpy(half.method_storage[0..method_value.len], method_value);
    half.method_len = @intCast(method_value.len);
    @memcpy(half.target_storage[0..target_value.len], target_value);
    half.target_len = @intCast(target_value.len);
}

pub fn setMethod(half: *Half, value: []const u8) void {
    if (value.len > half.method_storage.len) {
        half.head.truncated = true;
        return;
    }

    @memcpy(half.method_storage[0..value.len], value);
    half.method_len = @intCast(value.len);
}

pub fn setTarget(half: *Half, value: []const u8) void {
    if (value.len > half.target_storage.len) {
        half.head.truncated = true;
        return;
    }

    @memcpy(half.target_storage[0..value.len], value);
    half.target_len = @intCast(value.len);
}

pub fn setEncoding(half: *Half, value: []const u8) void {
    if (value.len > half.encoding_storage.len) {
        @memcpy(&half.encoding_storage, value[0..half.encoding_storage.len]);
        half.encoding_len = @intCast(half.encoding_storage.len);
        half.body.truncated = true;
        return;
    }

    @memcpy(half.encoding_storage[0..value.len], value);
    half.encoding_len = @intCast(value.len);
}

pub fn append(half: *Half, part: buffer_support.Part, input: []const u8) bool {
    const selected = switch (part) {
        .request_head => if (half.side == .request) &half.head else return false,
        .request_body => if (half.side == .request) &half.body else return false,
        .response_head => if (half.side == .response) &half.head else return false,
        .response_body => if (half.side == .response) &half.body else return false,
    };
    const available = half.reservation.bytes -| half.captured_bytes;
    const accepted = @min(available, input.len);

    if (accepted != 0) {
        const before = selected.len;
        _ = selected.append(input[0..accepted]);
        half.captured_bytes += selected.len - before;
    }

    if (accepted != input.len) {
        selected.truncated = true;
    }

    return accepted == input.len and !selected.truncated;
}

pub fn finish(half: *Half, outcome: buffer_support.Outcome, finished_at_ms: i64) void {
    half.outcome = outcome;
    half.finished_at_ms = finished_at_ms;
}

pub fn deinit(half: *Half) void {
    const gpa = half.gpa;
    half.head.deinit();
    half.body.deinit();
    half.reservation.release();
    std.crypto.secureZero(u8, std.mem.asBytes(half));
    gpa.destroy(half);
}

/// Records one relayed HTTP head: its bytes, the request line's method and
/// target, and the content encoding the body will need for decoding.
///
/// ```zig
/// half.appendHead(head_bytes);
/// ```
pub fn appendHead(self: *Half, bytes: []const u8) void {
    const part: buffer_support.Part = if (self.side == .request) .request_head else .response_head;
    _ = self.append(part, bytes);

    if (self.side == .request) {
        const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return;
        var fields = std.mem.splitScalar(u8, bytes[0..line_end], ' ');
        const request_method = fields.next() orelse return;
        const request_target = fields.next() orelse return;
        self.setRoute(request_method, request_target);
    }

    if (headerValue(bytes, "content-encoding")) |content_encoding| {
        self.setEncoding(content_encoding);
    }
}

fn headerValue(bytes: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted)) {
            continue;
        }

        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }

    return null;
}
