//! One direction of one captured exchange: its head and de-framed body
//! within a byte reservation, and the request line and content encoding
//! read from its head.
const std = @import("std");
const Reservation = @import("Reservation.zig");
const Key = @import("Key.zig");
const buffer_support = @import("buffer_support.zig");
const Buffer = @import("Buffer.zig");
const Quota = @import("Quota.zig");
const Config = @import("Config.zig");

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
        reservation: Reservation,
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

        pub fn create(options: Options) ?*Half {
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
            if (method_value.len > self.method_storage.len or target_value.len > self.target_storage.len) {
                self.head.truncated = true;
                return;
            }

            @memcpy(self.method_storage[0..method_value.len], method_value);
            self.method_len = @intCast(method_value.len);
            @memcpy(self.target_storage[0..target_value.len], target_value);
            self.target_len = @intCast(target_value.len);
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

        pub fn append(self: *Half, part: buffer_support.Part, input: []const u8) bool {
            const selected = switch (part) {
                .request_head => if (self.side == .request) &self.head else return false,
                .request_body => if (self.side == .request) &self.body else return false,
                .response_head => if (self.side == .response) &self.head else return false,
                .response_body => if (self.side == .response) &self.body else return false,
            };
            const available = self.reservation.bytes -| self.captured_bytes;
            const accepted = @min(available, input.len);

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
