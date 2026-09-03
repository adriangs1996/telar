//! Length-delimited protocol between the runtime and one tap worker.

const std = @import("std");
const core = @import("telar-core");
const effects = @import("effects.zig");
const proxy = @import("../proxy/root.zig");

pub const prefix_bytes = 4;
pub const overhead_bytes = 64 * 1024;

pub const Half = struct {
    head: []const u8,
    body: []const u8,
    encoding: []const u8,
    decoded: bool,
    head_truncated: bool,
    body_truncated: bool,
    status_code: u16,
    outcome: proxy.CaptureOutcome,
    finished_at_ms: i64,
};

pub const Exchange = struct {
    id: u64,
    generation: u64,
    pane: core.schema.PaneId,
    pane_generation: u64,
    host: []const u8,
    protocol: proxy.ObservationProtocol,
    dialect: proxy.ApiDialect,
    connection_id: u64,
    stream_id: u32,
    method: []const u8,
    target: []const u8,
    started_at_ms: i64,
    request: ?Half,
    response: ?Half,
};

/// Encodes one captured exchange into caller-owned frame payload storage.
///
/// ```zig
/// const payload = try encodeExchange(buffer, id, generation, &exchange);
/// ```
pub fn encodeExchange(buffer: []u8, id: u64, generation: u64, captured: *const proxy.CaptureExchange) ![]const u8 {
    const representative = captured.request orelse captured.response orelse return error.EmptyCapture;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(1);
    try writeInt(&writer, u64, id);
    try writeInt(&writer, u64, generation);
    try writeInt(&writer, u64, core.schema.id.raw(representative.pane.id));
    try writeInt(&writer, u64, representative.pane.generation);
    try writer.writeByte(@intFromEnum(representative.protocol));
    try writer.writeByte(@intFromEnum(representative.dialect));
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
pub fn decodeExchange(bytes: []const u8) !Exchange {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.byte() != 1) return error.UnknownFrame;
    const id = try cursor.int(u64);
    const generation = try cursor.int(u64);
    const pane = core.schema.id.pane(try cursor.int(u64)) catch return error.InvalidExchange;
    const pane_generation = try cursor.int(u64);
    const protocol = std.enums.fromInt(proxy.ObservationProtocol, try cursor.byte()) orelse return error.InvalidExchange;
    const dialect = std.enums.fromInt(proxy.ApiDialect, try cursor.byte()) orelse return error.InvalidExchange;
    const connection_id = try cursor.int(u64);
    const stream_id = try cursor.int(u32);
    const host = try cursor.sized();
    const method = try cursor.sized();
    const target = try cursor.sized();
    const started_at_ms = try cursor.int(i64);
    const request = try readHalf(&cursor);
    const response = try readHalf(&cursor);
    if (cursor.offset != bytes.len) return error.TrailingFrame;

    return .{
        .id = id,
        .generation = generation,
        .pane = pane,
        .pane_generation = pane_generation,
        .host = host,
        .protocol = protocol,
        .dialect = dialect,
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
pub fn encodeEffects(buffer: []u8, event_id: u64, batch: *const effects.Batch) ![]const u8 {
    if (batch.len > effects.max_effects) return error.TooManyEffects;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(2);
    try writeInt(&writer, u64, event_id);
    try writer.writeByte(batch.len);

    for (batch.slice()) |effect| switch (effect) {
        .record_command => |record| {
            try writer.writeByte(1);
            try writeSized(&writer, record.command);
            try writeSized(&writer, record.cwd);
            try writeSized(&writer, record.provider);
            try writer.writeByte(@intFromBool(record.session != null));
            if (record.session) |session| try writeSized(&writer, session);
            try writeInt(&writer, i32, record.exit_code);
            try writeInt(&writer, i64, record.started_at_ms);
            try writeInt(&writer, u64, record.duration_ms);
            try writer.writeByte(@intFromBool(record.redact));
        },
        .agent_evidence => |evidence| {
            try writer.writeByte(2);
            try writeInt(&writer, u64, core.schema.id.raw(evidence.pane));
            try writer.writeByte(@intFromEnum(evidence.state));
            try writer.writeByte(@intFromEnum(evidence.confidence));
        },
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
pub fn decodeEffects(bytes: []const u8) !struct { event_id: u64, batch: effects.Batch } {
    var cursor: Cursor = .{ .bytes = bytes };
    if (try cursor.byte() != 2) return error.UnknownFrame;
    const event_id = try cursor.int(u64);
    const count = try cursor.byte();
    if (count > effects.max_effects) return error.TooManyEffects;
    var batch: effects.Batch = .{ .len = count };

    for (0..count) |index| {
        batch.items[index] = switch (try cursor.byte()) {
            1 => .{ .record_command = .{
                .command = try cursor.sized(),
                .cwd = try cursor.sized(),
                .provider = try cursor.sized(),
                .session = if (try cursor.boolean()) try cursor.sized() else null,
                .exit_code = try cursor.int(i32),
                .started_at_ms = try cursor.int(i64),
                .duration_ms = try cursor.int(u64),
                .redact = try cursor.boolean(),
            } },
            2 => .{ .agent_evidence = .{
                .pane = core.schema.id.pane(try cursor.int(u64)) catch return error.InvalidEffect,
                .state = std.enums.fromInt(core.schema.AgentReportState, try cursor.byte()) orelse return error.InvalidEffect,
                .confidence = std.enums.fromInt(effects.Confidence, try cursor.byte()) orelse return error.InvalidEffect,
            } },
            3 => .{ .notification = .{
                .level = std.enums.fromInt(core.schema.NotificationLevel, try cursor.byte()) orelse return error.InvalidEffect,
                .duration_ms = try cursor.int(u32),
                .title = try cursor.sized(),
                .message = try cursor.sized(),
            } },
            else => return error.UnknownEffect,
        };
    }
    if (cursor.offset != bytes.len) return error.TrailingFrame;
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
    if (try cursor.byte() != 3) return error.UnknownFrame;
    const event_id = try cursor.int(u64);
    const message = try cursor.sized();
    if (cursor.offset != bytes.len) return error.TrailingFrame;
    return .{ .event_id = event_id, .message = message };
}

fn writeHalf(writer: *std.Io.Writer, optional: ?*proxy.CaptureHalf) !void {
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

fn readHalf(cursor: *Cursor) !?Half {
    if (!try cursor.boolean()) return null;
    return .{
        .head = try cursor.sized(),
        .body = try cursor.sized(),
        .encoding = try cursor.sized(),
        .decoded = try cursor.boolean(),
        .head_truncated = try cursor.boolean(),
        .body_truncated = try cursor.boolean(),
        .status_code = try cursor.int(u16),
        .outcome = std.enums.fromInt(proxy.CaptureOutcome, try cursor.byte()) orelse return error.InvalidExchange,
        .finished_at_ms = try cursor.int(i64),
    };
}

fn writeSized(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.FrameTooLarge;
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

    fn byte(cursor: *Cursor) !u8 {
        if (cursor.offset == cursor.bytes.len) return error.TruncatedFrame;
        defer cursor.offset += 1;
        return cursor.bytes[cursor.offset];
    }

    fn boolean(cursor: *Cursor) !bool {
        return switch (try cursor.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }

    fn int(cursor: *Cursor, comptime T: type) !T {
        if (cursor.bytes.len -| cursor.offset < @sizeOf(T)) return error.TruncatedFrame;
        defer cursor.offset += @sizeOf(T);
        return std.mem.readInt(T, cursor.bytes[cursor.offset..][0..@sizeOf(T)], .little);
    }

    fn sized(cursor: *Cursor) ![]const u8 {
        const len = try cursor.int(u32);
        if (cursor.bytes.len -| cursor.offset < len) return error.TruncatedFrame;
        defer cursor.offset += len;
        return cursor.bytes[cursor.offset..][0..len];
    }
};

test "effect protocol round trips all effect variants and rejects trailing bytes" {
    var batch: effects.Batch = .{ .len = 3 };
    batch.items[0] = .{ .record_command = .{
        .command = "git status",
        .cwd = "/work",
        .provider = "codex",
        .session = "session-1",
        .exit_code = 0,
        .started_at_ms = 10,
        .duration_ms = 20,
        .redact = true,
    } };
    batch.items[1] = .{ .agent_evidence = .{ .pane = @enumFromInt(7), .state = .working, .confidence = .medium } };
    batch.items[2] = .{ .notification = .{ .level = .warning, .duration_ms = 3000, .title = "Tap", .message = "Observed" } };
    var storage: [2048]u8 = undefined;
    const encoded = try encodeEffects(&storage, 9, &batch);
    const decoded = try decodeEffects(encoded);
    try std.testing.expectEqual(@as(u64, 9), decoded.event_id);
    try std.testing.expectEqualStrings("git status", decoded.batch.items[0].record_command.command);
    try std.testing.expectEqual(core.schema.AgentReportState.working, decoded.batch.items[1].agent_evidence.state);
    try std.testing.expectEqualStrings("Observed", decoded.batch.items[2].notification.message);
    storage[encoded.len] = 0;
    try std.testing.expectError(error.TrailingFrame, decodeEffects(storage[0 .. encoded.len + 1]));
}

test "worker error protocol round trips and rejects trailing bytes" {
    var storage: [128]u8 = undefined;
    const encoded = try encodeError(&storage, 41, "budget exceeded");
    const decoded = try decodeError(encoded);
    try std.testing.expectEqual(@as(u64, 41), decoded.event_id);
    try std.testing.expectEqualStrings("budget exceeded", decoded.message);
    storage[encoded.len] = 0;
    try std.testing.expectError(error.TrailingFrame, decodeError(storage[0 .. encoded.len + 1]));
}
