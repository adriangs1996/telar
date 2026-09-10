//! Bounded, scrubbed storage for one captured exchange part.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");

pub const default_max_part_bytes = core.proxy.default_capture_part_bytes;
pub const default_max_exchange_bytes = core.proxy.default_capture_exchange_bytes;
pub const default_max_total_bytes = core.proxy.default_capture_total_bytes;
pub const default_join_timeout_ms = core.proxy.default_capture_join_timeout_ms;
pub const max_host_bytes = 255;
pub const max_method_bytes = 32;
pub const max_target_bytes = 8 * 1024;
pub const max_encoding_bytes = 128;

pub const Config = struct {
    enabled: bool = false,
    max_part_bytes: usize = default_max_part_bytes,
    max_exchange_bytes: usize = default_max_exchange_bytes,
    max_total_bytes: usize = default_max_total_bytes,
    join_timeout_ms: u32 = default_join_timeout_ms,

    pub fn validate(config: Config) !void {
        if (config.max_part_bytes == 0 or config.max_exchange_bytes < 2 or config.max_total_bytes == 0) {
            return error.InvalidCaptureQuota;
        }

        if (config.max_part_bytes > config.max_exchange_bytes or config.max_exchange_bytes > config.max_total_bytes) {
            return error.InvalidCaptureQuota;
        }

        if (config.join_timeout_ms == 0) {
            return error.InvalidCaptureTimeout;
        }
    }
};

pub const Part = enum {
    request_head,
    request_body,
    response_head,
    response_body,
};

pub const Side = enum {
    request,
    response,
};

pub const Outcome = enum {
    finished,
    failed,
    reset,
};

pub const Key = struct {
    connection_id: u64,
    stream_id: u32,
};

pub const Pane = struct {
    id: core.schema.PaneId,
    generation: u64,
};

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    storage: []u8 = &.{},
    len: usize = 0,
    max_bytes: usize,
    truncated: bool = false,

    pub fn init(gpa: std.mem.Allocator, max_bytes: usize) Buffer {
        return .{ .gpa = gpa, .max_bytes = max_bytes };
    }

    pub fn append(buffer: *Buffer, input: []const u8) bool {
        const available = buffer.max_bytes -| buffer.len;
        const accepted = @min(available, input.len);

        if (accepted != 0 and !buffer.ensureCapacity(buffer.len + accepted)) {
            buffer.truncated = true;
            return false;
        }

        if (accepted != 0) {
            @memcpy(buffer.storage[buffer.len..][0..accepted], input[0..accepted]);
            buffer.len += accepted;
        }

        if (accepted != input.len) {
            buffer.truncated = true;
        }

        return accepted == input.len;
    }

    pub fn bytes(buffer: *const Buffer) []const u8 {
        return buffer.storage[0..buffer.len];
    }

    pub fn reset(buffer: *Buffer) void {
        std.crypto.secureZero(u8, buffer.storage[0..buffer.len]);
        buffer.len = 0;
        buffer.truncated = false;
    }

    pub fn deinit(buffer: *Buffer) void {
        if (buffer.storage.len != 0) {
            std.crypto.secureZero(u8, buffer.storage);
            buffer.gpa.free(buffer.storage);
        }

        buffer.storage = &.{};
        buffer.len = 0;
        buffer.truncated = false;
    }

    fn ensureCapacity(buffer: *Buffer, needed: usize) bool {
        if (needed <= buffer.storage.len) {
            return true;
        }

        var capacity = @min(buffer.max_bytes, @max(@as(usize, 256), buffer.storage.len));
        while (capacity < needed) {
            capacity = @min(buffer.max_bytes, capacity *| 2);
            if (capacity < needed and capacity == buffer.max_bytes) {
                return false;
            }
        }

        const replacement = buffer.gpa.alloc(u8, capacity) catch return false;
        @memcpy(replacement[0..buffer.len], buffer.storage[0..buffer.len]);
        if (buffer.storage.len != 0) {
            std.crypto.secureZero(u8, buffer.storage);
            buffer.gpa.free(buffer.storage);
        }

        buffer.storage = replacement;
        return true;
    }
};

pub const Quota = struct {
    max_bytes: usize,
    reserved: std.atomic.Value(usize) = .init(0),

    pub fn init(max_bytes: usize) Quota {
        return .{ .max_bytes = max_bytes };
    }

    pub fn reserve(quota: *Quota, bytes: usize) ?Reservation {
        var current = quota.reserved.load(.monotonic);

        while (bytes <= quota.max_bytes -| current) {
            if (quota.reserved.cmpxchgWeak(current, current + bytes, .monotonic, .monotonic)) |observed| {
                current = observed;
                continue;
            }

            return .{ .quota = quota, .bytes = bytes };
        }

        return null;
    }

    pub fn used(quota: *const Quota) usize {
        return quota.reserved.load(.monotonic);
    }
};

pub const Reservation = struct {
    quota: *Quota,
    bytes: usize,

    fn release(reservation: *Reservation) void {
        if (reservation.bytes == 0) {
            return;
        }

        const previous = reservation.quota.reserved.fetchSub(reservation.bytes, .monotonic);
        std.debug.assert(previous >= reservation.bytes);
        reservation.bytes = 0;
    }
};

pub const HalfOptions = struct {
    gpa: std.mem.Allocator,
    quota: *Quota,
    config: Config,
    credential: identity.Credential,
    dialect: middleware.ApiDialect,
    protocol: middleware.Protocol,
    key: Key,
    side: Side,
    host: []const u8,
    started_at_ms: i64,
};

pub const Half = struct {
    gpa: std.mem.Allocator,
    reservation: Reservation,
    pane: Pane,
    dialect: middleware.ApiDialect,
    protocol: middleware.Protocol,
    key: Key,
    side: Side,
    head: Buffer,
    body: Buffer,
    host_storage: [max_host_bytes]u8 = undefined,
    host_len: u16 = 0,
    method_storage: [max_method_bytes]u8 = undefined,
    method_len: u8 = 0,
    target_storage: [max_target_bytes]u8 = undefined,
    target_len: u16 = 0,
    encoding_storage: [max_encoding_bytes]u8 = undefined,
    encoding_len: u8 = 0,
    status_code: u16 = 0,
    started_at_ms: i64,
    finished_at_ms: i64 = 0,
    outcome: Outcome = .failed,
    captured_bytes: usize = 0,
    body_decoded: bool = false,

    pub fn create(options: HalfOptions) ?*Half {
        if (!options.config.enabled) {
            return null;
        }

        const reservation_bytes = @max(@as(usize, 1), options.config.max_exchange_bytes / 2);
        var reservation = options.quota.reserve(reservation_bytes) orelse return null;

        if (options.host.len > max_host_bytes) {
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

    pub fn append(half: *Half, part: Part, input: []const u8) bool {
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

    pub fn finish(half: *Half, outcome: Outcome, finished_at_ms: i64) void {
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
};

test "buffer grows within its bound and scrubs owned storage" {
    var buffer = Buffer.init(std.testing.allocator, 5);
    defer buffer.deinit();

    try std.testing.expect(buffer.append("abc"));
    try std.testing.expect(!buffer.append("def"));
    try std.testing.expectEqualStrings("abcde", buffer.bytes());
    try std.testing.expect(buffer.truncated);
}

test "quota reservations remain bounded and release exactly once" {
    var quota = Quota.init(8);
    var first = quota.reserve(5).?;
    try std.testing.expect(quota.reserve(4) == null);
    var second = quota.reserve(3).?;
    try std.testing.expectEqual(@as(usize, 8), quota.used());

    first.release();
    second.release();
    second.release();
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}

test "capture config rejects impossible bounds" {
    try (Config{}).validate();
    try std.testing.expectError(error.InvalidCaptureQuota, (Config{ .max_part_bytes = 9, .max_exchange_bytes = 8 }).validate());
    try std.testing.expectError(error.InvalidCaptureQuota, (Config{ .max_exchange_bytes = 9, .max_total_bytes = 8 }).validate());
    try std.testing.expectError(error.InvalidCaptureTimeout, (Config{ .join_timeout_ms = 0 }).validate());
}
