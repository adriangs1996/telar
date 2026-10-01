//! One direction of one captured exchange: its head and de-framed body
//! within its share of the exchange bound, and the request line and content
//! encoding read from its head. The half's reservation is the storage its
//! buffers hold, charged before they grow, so a half that is still empty,
//! such as one waiting on an idle keep-alive connection, holds none, and
//! the quota bounds the heap capture uses, copies while growing included.
const std = @import("std");
const Reservation = @import("Reservation.zig");
const Key = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const Buffer = @import("Buffer.zig");
const Quota = @import("Quota.zig");
const Config = @import("Config.zig");
const Truncation = @import("Truncation.zig");

/// A half owned by `Meta`, the caller's record of who the exchange belongs
/// to.
///
/// ```zig
/// const Half = GenericHalf(Owner);
/// ```
pub fn Type(comptime Meta: type) type {
    return struct {
        const Half = @This();

        gpa: std.mem.Allocator,
        /// Quota this half holds: the storage of its head and body buffers.
        reservation: Reservation,
        /// This half's share of `max_exchange_bytes`: head and body together.
        max_bytes: usize,
        /// The caller's description of who owns the exchange; never read here.
        meta: Meta,
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
        truncation: Truncation = .{},

        pub fn create(options: Options) ?*Half {
            if (!options.config.enabled) {
                return null;
            }

            if (options.host.len > buffer_support.max_host_bytes) {
                return null;
            }

            const half = options.gpa.create(Half) catch return null;
            half.* = .{
                .gpa = options.gpa,
                .reservation = .{
                    .quota = options.quota,
                    .bytes = 0,
                },
                .max_bytes = shareOf(options.config),
                .meta = options.meta,
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

        /// The bytes one half may capture: head and body together get half
        /// of `max_exchange_bytes`, so request and response split it evenly.
        ///
        /// ```zig
        /// const share = Half.shareOf(config);
        /// ```
        pub fn shareOf(config: Config) usize {
            return @max(@as(usize, 1), config.max_exchange_bytes / 2);
        }

        pub fn host(self: *const Half) []const u8 {
            return self.host_storage[0..self.host_len];
        }

        pub fn method(self: *const Half) []const u8 {
            return self.method_storage[0..self.method_len];
        }

        pub fn target(self: *const Half) []const u8 {
            return self.target_storage[0..self.target_len];
        }

        pub fn encoding(self: *const Half) []const u8 {
            return self.encoding_storage[0..self.encoding_len];
        }

        pub fn setRoute(self: *Half, method_value: []const u8, target_value: []const u8) void {
            self.setMethod(method_value);
            self.setTarget(target_value);
        }

        pub fn setMethod(self: *Half, value: []const u8) void {
            if (value.len > self.method_storage.len) {
                self.head.truncated = true;
                return;
            }

            @memcpy(self.method_storage[0..value.len], value);
            self.method_len = @intCast(value.len);
        }

        pub fn setTarget(self: *Half, value: []const u8) void {
            if (value.len > self.target_storage.len) {
                self.head.truncated = true;
                return;
            }

            @memcpy(self.target_storage[0..value.len], value);
            self.target_len = @intCast(value.len);
        }

        pub fn setEncoding(self: *Half, value: []const u8) void {
            if (value.len > self.encoding_storage.len) {
                @memcpy(&self.encoding_storage, value[0..self.encoding_storage.len]);
                self.encoding_len = @intCast(self.encoding_storage.len);
                self.body.truncated = true;
                return;
            }

            @memcpy(self.encoding_storage[0..value.len], value);
            self.encoding_len = @intCast(value.len);
        }

        /// Captures what fits of one fragment and records the first bound
        /// that cut it: the part's `max_part_bytes`, the half's share of
        /// `max_exchange_bytes`, or the quota every capture shares. Returns
        /// whether the whole fragment fit.
        ///
        /// ```zig
        /// _ = half.append(.request_body, fragment);
        /// ```
        pub fn append(self: *Half, part: buffer_support.Part, input: []const u8) bool {
            const selected = switch (part) {
                .request_head => if (self.side == .request) &self.head else return false,
                .request_body => if (self.side == .request) &self.body else return false,
                .response_head => if (self.side == .response) &self.head else return false,
                .response_body => if (self.side == .response) &self.body else return false,
            };

            const part_room = selected.max_bytes -| selected.len;
            const half_room = self.max_bytes -| self.captured_bytes;
            const allowed = @min(input.len, part_room, half_room);
            if (allowed != input.len) {
                if (part_room <= half_room) {
                    self.truncation.part = true;
                } else {
                    self.truncation.exchange = true;
                }
            }

            const accepted = self.reserve(selected, allowed);
            if (accepted != allowed) {
                self.truncation.total = true;
            }

            if (accepted != 0) {
                const before = selected.len;
                _ = selected.append(input[0..accepted]);
                self.captured_bytes += selected.len - before;
            }

            if (accepted != input.len) {
                selected.truncated = true;
            }

            return accepted == input.len and !selected.truncated;
        }

        /// Grows `buffer` to hold `bytes` more when the quota covers its new
        /// storage, and returns how many of them fit. The new storage is
        /// charged before it is allocated and the old storage released
        /// after the copy, so the quota covers both while they coexist; a
        /// quota that covers less grows the buffer only as far as it goes.
        fn reserve(self: *Half, buffer: *Buffer, bytes: usize) usize {
            const needed = buffer.len + bytes;
            const old_capacity = buffer.storage.len;
            if (needed <= old_capacity) {
                return bytes;
            }

            const capacity = self.reservation.grow(buffer.grownCapacity(needed));
            if (capacity <= old_capacity or !buffer.growTo(capacity)) {
                self.reservation.shrink(capacity);
                return old_capacity - buffer.len;
            }

            self.reservation.shrink(old_capacity);
            return @min(bytes, capacity - buffer.len);
        }

        pub fn finish(self: *Half, outcome: buffer_support.Outcome, finished_at_ms: i64) void {
            self.outcome = outcome;
            self.finished_at_ms = finished_at_ms;
        }

        pub fn deinit(self: *Half) void {
            const gpa = self.gpa;
            self.head.deinit();
            self.body.deinit();
            self.reservation.release();
            std.crypto.secureZero(u8, std.mem.asBytes(self));
            gpa.destroy(self);
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

        /// What a new half needs: its quota and bounds, its owner, and which side
        /// of which exchange it records.
        pub const Options = struct {
            gpa: std.mem.Allocator,
            quota: *Quota,
            config: Config,
            meta: Meta,
            key: Key,
            side: buffer_support.Side,
            host: []const u8,
            started_at_ms: i64,
        };
    };
}

/// The owner the tests attach to each half.
const TestOwner = struct { id: u64 };
const TestHalf = Type(TestOwner);

fn testHalf(quota: *Quota, config: Config) *TestHalf {
    return TestHalf.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = config,
        .meta = .{
            .id = 1,
        },
        .key = .{
            .connection_id = 1,
            .stream_id = 0,
        },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
}

test "an empty half holds no quota and the quota holds its buffers' storage" {
    var quota = Quota.init(64);
    const half = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 32,
        .max_exchange_bytes = 64,
        .max_total_bytes = 64,
    });

    try std.testing.expectEqual(@as(usize, 0), quota.used());
    try std.testing.expect(half.append(.request_body, "hello"));
    try std.testing.expectEqual(half.body.storage.len, quota.used());
    try std.testing.expect(!half.truncation.any());

    half.deinit();
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}

test "growing charges the new storage before the old is freed" {
    var quota = Quota.init(1024);
    const half = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 1024,
        .max_exchange_bytes = 2048,
        .max_total_bytes = 2048,
    });
    defer half.deinit();
    const fragment: [300]u8 = @splat('x');

    try std.testing.expect(half.append(.request_body, &fragment));
    try std.testing.expectEqual(@as(usize, 512), half.body.storage.len);
    try std.testing.expectEqual(@as(usize, 512), quota.used());

    try std.testing.expect(!half.append(.request_body, &fragment));
    try std.testing.expectEqual(@as(usize, 512), half.body.len);
    try std.testing.expectEqual(@as(usize, 512), quota.used());
    try std.testing.expect(half.truncation.total);
}

test "a spent quota keeps what fits and names the total bound" {
    var quota = Quota.init(4);
    const half = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 32,
        .max_exchange_bytes = 64,
        .max_total_bytes = 64,
    });
    defer half.deinit();

    try std.testing.expect(!half.append(.request_body, "hello"));
    try std.testing.expectEqualStrings("hell", half.body.bytes());
    try std.testing.expect(half.body.truncated);
    const cut_by_total: Truncation = .{
        .total = true,
    };
    try std.testing.expectEqual(cut_by_total, half.truncation);
    try std.testing.expectEqual(@as(usize, 4), quota.used());
}

test "the part bound and the exchange share name their own cause" {
    var quota = Quota.init(64);
    const parts = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 4,
        .max_exchange_bytes = 64,
        .max_total_bytes = 64,
    });
    defer parts.deinit();

    try std.testing.expect(!parts.append(.request_body, "hello"));
    try std.testing.expectEqualStrings("hell", parts.body.bytes());
    const cut_by_part: Truncation = .{
        .part = true,
    };
    try std.testing.expectEqual(cut_by_part, parts.truncation);

    const shared = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 8,
        .max_exchange_bytes = 12,
        .max_total_bytes = 64,
    });
    defer shared.deinit();

    try std.testing.expect(shared.append(.request_head, "head"));
    try std.testing.expect(!shared.append(.request_body, "hello"));
    try std.testing.expectEqualStrings("he", shared.body.bytes());
    const cut_by_exchange: Truncation = .{
        .exchange = true,
    };
    try std.testing.expectEqual(cut_by_exchange, shared.truncation);
}

test "a request target past its bound keeps the method" {
    var quota = Quota.init(64);
    const half = testHalf(&quota, .{
        .enabled = true,
        .max_part_bytes = 32,
        .max_exchange_bytes = 64,
        .max_total_bytes = 64,
    });
    defer half.deinit();
    const target: [buffer_support.max_target_bytes + 1]u8 = @splat('a');

    half.setRoute("POST", &target);
    try std.testing.expectEqualStrings("POST", half.method());
    try std.testing.expectEqualStrings("", half.target());
    try std.testing.expect(half.head.truncated);
}
