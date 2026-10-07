//! Length-delimited protocol between the runtime and one tap worker.

const exchangecapture = @import("exchangecapture");
const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const ExchangeIdentity = @import("ExchangeIdentity.zig");
const Exchange = owned.Exchange;
const std = @import("std");
const ExchangeType = @import("Exchange.zig");
const Protocol = @import("../proxy/Protocol.zig").Protocol;
const Batch = @import("Batch.zig");
const effects = @import("effects.zig");
const Half = owned.Half;
const HalfType = @import("Half.zig");
const buffer_support = exchangecapture.buffer_support;

pub const prefix_bytes = 4;
pub const overhead_bytes = 64 * 1024;

/// Encodes one captured exchange into caller-owned frame payload storage.
///
/// ```zig
/// const payload = try encodeExchange(buffer, .{ .id = id, .generation = generation }, &exchange);
/// ```
pub fn encodeExchange(buffer: []u8, identity: ExchangeIdentity, captured: *const Exchange) ![]const u8 {
    const representative = captured.request orelse captured.response orelse return error.EmptyCapture;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(1);
    try writeInt(&writer, u64, identity.id);
    try writeInt(&writer, u64, identity.generation);
    try writer.writeByte(@intFromEnum(representative.meta.protocol));
    try writeInt(&writer, u64, representative.key.connection_id);
    try writeInt(&writer, u32, representative.key.stream_id);
    try writeSized(&writer, representative.host());
    try writeSized(&writer, representative.method());
    try writeSized(&writer, representative.target());
    try writeInt(&writer, i64, representative.started_at_ms);
    try writeHalf(&writer, captured.request);
    try writeHalf(&writer, captured.response);
    return writer.buffered();
}

/// Decodes one exchange payload and rejects unknown tags or trailing bytes.
///
/// ```zig
/// const exchange = try decodeExchange(payload);
/// ```
pub fn decodeExchange(bytes: []const u8) !ExchangeType {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.byte() != 1) {
        return error.UnknownFrame;
    }
    const id = try cursor.int(u64);
    const generation = try cursor.int(u64);
    const protocol = std.enums.fromInt(Protocol, try cursor.byte()) orelse return error.InvalidExchange;
    const connection_id = try cursor.int(u64);
    const stream_id = try cursor.int(u32);
    const host = try cursor.sized();
    const method = try cursor.sized();
    const target = try cursor.sized();
    const started_at_ms = try cursor.int(i64);
    const request = try readHalf(&cursor);
    const response = try readHalf(&cursor);
    if (cursor.offset != bytes.len) {
        return error.TrailingFrame;
    }

    return .{
        .id = id,
        .generation = generation,
        .host = host,
        .protocol = protocol,
        .connection_id = connection_id,
        .stream_id = stream_id,
        .method = method,
        .target = target,
        .started_at_ms = started_at_ms,
        .request = request,
        .response = response,
    };
}

/// Encodes one effect batch with its originating exchange ID.
///
/// ```zig
/// const payload = try encodeEffects(buffer, event_id, &batch);
/// ```
pub fn encodeEffects(buffer: []u8, event_id: u64, batch: *const Batch) ![]const u8 {
    if (batch.len > effects.max_effects) {
        return error.TooManyEffects;
    }
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(2);
    try writeInt(&writer, u64, event_id);
    try writer.writeByte(batch.len);

    for (batch.slice()) |effect| switch (effect) {
        .notification => |notification| {
            try writer.writeByte(3);
            try writer.writeByte(@intFromEnum(notification.level));
            try writeInt(&writer, u32, notification.duration_ms);
            try writeSized(&writer, notification.title);
            try writeSized(&writer, notification.message);
        },
    };

    return writer.buffered();
}

/// Decodes one effect batch whose string slices borrow the input frame.
///
/// ```zig
/// const decoded = try decodeEffects(payload);
/// ```
pub fn decodeEffects(bytes: []const u8) !struct { event_id: u64, batch: Batch } {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.byte() != 2) {
        return error.UnknownFrame;
    }
    const event_id = try cursor.int(u64);
    const count = try cursor.byte();
    if (count > effects.max_effects) {
        return error.TooManyEffects;
    }
    var batch: Batch = .{ .len = count };

    for (0..count) |index| {
        batch.items[index] = switch (try cursor.byte()) {
            3 => .{ .notification = .{
                .level = std.enums.fromInt(core.NotificationLevel, try cursor.byte()) orelse return error.InvalidEffect,
                .duration_ms = try cursor.int(u32),
                .title = try cursor.sized(),
                .message = try cursor.sized(),
            } },
            else => return error.UnknownEffect,
        };
    }
    if (cursor.offset != bytes.len) {
        return error.TrailingFrame;
    }
    return .{ .event_id = event_id, .batch = batch };
}

/// Encodes a bounded worker-side callback failure without terminating the worker.
///
/// ```zig
/// const payload = try encodeError(buffer, event_id, "budget exceeded");
/// ```
pub fn encodeError(buffer: []u8, event_id: u64, message: []const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(3);
    try writeInt(&writer, u64, event_id);
    try writeSized(&writer, message[0..@min(message.len, 4096)]);
    return writer.buffered();
}

/// Decodes a strict worker error frame whose message borrows the input.
///
/// ```zig
/// const failure = try decodeError(payload);
/// ```
pub fn decodeError(bytes: []const u8) !struct { event_id: u64, message: []const u8 } {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.byte() != 3) {
        return error.UnknownFrame;
    }
    const event_id = try cursor.int(u64);
    const message = try cursor.sized();
    if (cursor.offset != bytes.len) {
        return error.TrailingFrame;
    }
    return .{ .event_id = event_id, .message = message };
}

fn writeHalf(writer: *std.Io.Writer, optional: ?*Half) !void {
    try writer.writeByte(@intFromBool(optional != null));
    const half = optional orelse return;
    try writeSized(writer, half.head.bytes());
    try writeSized(writer, half.body.bytes());
    try writeSized(writer, half.encoding());
    try writer.writeByte(@intFromBool(half.body_decoded));
    try writer.writeByte(@intFromBool(half.head.truncated));
    try writer.writeByte(@intFromBool(half.body.truncated));
    try writeInt(writer, u16, half.status_code);
    try writer.writeByte(@intFromEnum(half.outcome));
    try writeInt(writer, i64, half.finished_at_ms);
}

fn readHalf(cursor: *Cursor) !?HalfType {
    if (!try cursor.boolean()) {
        return null;
    }
    const head = try cursor.sized();
    const body = try cursor.sized();
    const encoding = try cursor.sized();
    const decoded = try cursor.boolean();

    // The head's truncation flag stays on the wire; nothing reads it.
    _ = try cursor.boolean();
    return .{
        .head = head,
        .body = body,
        .encoding = encoding,
        .decoded = decoded,
        .body_truncated = try cursor.boolean(),
        .status_code = try cursor.int(u16),
        .outcome = std.enums.fromInt(buffer_support.Outcome, try cursor.byte()) orelse return error.InvalidExchange,
        .finished_at_ms = try cursor.int(i64),
    };
}

fn writeSized(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) {
        return error.FrameTooLarge;
    }
    try writeInt(writer, u32, @intCast(bytes.len));
    try writer.writeAll(bytes);
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn byte(self: *Cursor) !u8 {
        if (self.offset == self.bytes.len) {
            return error.TruncatedFrame;
        }
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    pub fn boolean(self: *Cursor) !bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }

    pub fn int(self: *Cursor, comptime T: type) !T {
        if (self.bytes.len -| self.offset < @sizeOf(T)) {
            return error.TruncatedFrame;
        }
        defer self.offset += @sizeOf(T);
        return std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
    }

    pub fn sized(self: *Cursor) ![]const u8 {
        const len = try self.int(u32);
        if (self.bytes.len -| self.offset < len) {
            return error.TruncatedFrame;
        }
        defer self.offset += len;
        return self.bytes[self.offset..][0..len];
    }
};
