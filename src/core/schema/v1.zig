//! Application messages for telar protocol version 1.
//!
//! The handshake selects this schema before either peer calls these decoders.
//! Every function borrows input and caller-owned output memory; none allocates.

const std = @import("std");
const wire = @import("v1/wire.zig");

pub const frame = @import("v1/frame.zig");

pub const max_input_bytes = 64 * 1024;
pub const max_cwd_bytes = 4096;
pub const max_argument_count = 64;
pub const max_argument_bytes = 128 * 1024;
pub const max_environment_count = 256;
pub const max_environment_bytes = 512 * 1024;
pub const max_error_message_bytes = 1024;

pub const ClientTag = enum(u8) {
    open_pane = 0x01,
    pane_input = 0x02,
    pane_resize = 0x03,
    frame_ack = 0x04,
    request_snapshot = 0x05,
    detach_pane = 0x06,
    runtime_stop = 0x07,
};

pub const ServerTag = enum(u8) {
    pane_opened = 0x81,
    pane_frame = 0x82,
    pane_exited = 0x83,
    request_failed = 0x84,
    runtime_stopping = 0x85,
};

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,

    pub fn validate(size: TerminalSize) !void {
        if (size.cols == 0 or size.rows == 0) return error.InvalidTerminalSize;
        const cells = @as(u32, size.cols) * @as(u32, size.rows);
        if (cells > frame.max_cell_count) return error.ScreenTooLarge;
    }
};

pub const PaneTarget = union(enum) {
    default,
    pane: u64,
};

pub const EnvironmentMode = enum(u8) {
    inherit_runtime = 0,
    replace = 1,
};

pub const EnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Launch = struct {
    cwd: []const u8,
    arguments: []const []const u8,
    environment_mode: EnvironmentMode = .inherit_runtime,
    environment: []const EnvironmentEntry = &.{},
};

pub const LaunchView = struct {
    cwd: []const u8,
    argument_count: u16,
    encoded_arguments: []const u8,
    environment_mode: EnvironmentMode,
    environment_count: u16,
    encoded_environment: []const u8,

    pub fn arguments(launch: LaunchView) ArgumentIterator {
        return .{
            .decoder = .init(launch.encoded_arguments),
            .remaining = launch.argument_count,
        };
    }

    pub fn environment(launch: LaunchView) EnvironmentIterator {
        return .{
            .decoder = .init(launch.encoded_environment),
            .remaining = launch.environment_count,
        };
    }
};

pub const ArgumentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *ArgumentIterator) ?[]const u8 {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return iterator.decoder.readSized16() catch unreachable;
    }
};

pub const EnvironmentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *EnvironmentIterator) ?EnvironmentEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return .{
            .name = iterator.decoder.readSized16() catch unreachable,
            .value = iterator.decoder.readSized32() catch unreachable,
        };
    }
};

/// Opens the default pane, creating it from `launch` when none exists, or
/// attaches to a specific existing pane. This makes attach-or-create atomic.
pub const OpenPane = struct {
    request_id: u64,
    target: PaneTarget = .default,
    size: TerminalSize,
    launch: ?Launch,
};

pub const OpenPaneView = struct {
    request_id: u64,
    target: PaneTarget,
    size: TerminalSize,
    launch: ?LaunchView,
};

pub const PaneInput = struct {
    pane_id: u64,
    bytes: []const u8,
};

pub const PaneResize = struct {
    pane_id: u64,
    size: TerminalSize,
};

pub const FrameAck = struct {
    pane_id: u64,
    frame_id: u64,
};

pub const RequestSnapshot = struct {
    pane_id: u64,
    /// Last frame applied by the client. Zero means it has no pane state.
    known_frame_id: u64,
};

pub const DetachPane = struct {
    pane_id: u64,
};

pub const ClientMessage = union(enum) {
    open_pane: OpenPaneView,
    pane_input: PaneInput,
    pane_resize: PaneResize,
    frame_ack: FrameAck,
    request_snapshot: RequestSnapshot,
    detach_pane: DetachPane,
    runtime_stop: void,
};

pub const PaneOpened = struct {
    request_id: u64,
    pane_id: u64,
    created: bool,
};

pub const ExitKind = enum(u8) {
    exited = 0,
    signaled = 1,
};

pub const PaneExited = struct {
    pane_id: u64,
    kind: ExitKind,
    value: u32,
};

pub const FailureCode = enum(u16) {
    pane_not_found = 1,
    invalid_request = 2,
    spawn_failed = 3,
    permission_denied = 4,
    resource_limit = 5,
    internal = 6,
};

pub const RequestFailed = struct {
    /// Zero identifies a connection-level error rather than a request.
    request_id: u64,
    code: FailureCode,
    message: []const u8,
};

pub const ServerMessage = union(enum) {
    pane_opened: PaneOpened,
    pane_frame: frame.FrameView,
    pane_exited: PaneExited,
    request_failed: RequestFailed,
    runtime_stopping: void,
};

pub fn encodeOpenPane(buffer: []u8, message: OpenPane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.open_pane));
    try encoder.writeInt(u64, message.request_id);
    var default_launch: ?Launch = null;
    switch (message.target) {
        .default => {
            try encoder.writeByte(0);
            default_launch = message.launch orelse return error.MissingLaunch;
        },
        .pane => |pane_id| {
            try validatePaneId(pane_id);
            if (message.launch != null) return error.UnexpectedLaunch;
            try encoder.writeByte(1);
            try encoder.writeInt(u64, pane_id);
        },
    }
    try encodeSize(&encoder, message.size);
    if (default_launch) |launch| try encodeLaunch(&encoder, launch);
    return encoder.finish();
}

pub fn encodePaneInput(buffer: []u8, message: PaneInput) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.bytes.len == 0 or message.bytes.len > max_input_bytes)
        return error.InvalidInputLength;

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.pane_input));
    try encoder.writeInt(u64, message.pane_id);
    try encoder.writeBytes(message.bytes);
    return encoder.finish();
}

pub fn encodePaneResize(buffer: []u8, message: PaneResize) ![]const u8 {
    try validatePaneId(message.pane_id);
    try message.size.validate();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.pane_resize));
    try encoder.writeInt(u64, message.pane_id);
    try encodeSize(&encoder, message.size);
    return encoder.finish();
}

pub fn encodeFrameAck(buffer: []u8, message: FrameAck) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.frame_id == 0) return error.InvalidFrameId;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.frame_ack));
    try encoder.writeInt(u64, message.pane_id);
    try encoder.writeInt(u64, message.frame_id);
    return encoder.finish();
}

pub fn encodeRequestSnapshot(buffer: []u8, message: RequestSnapshot) ![]const u8 {
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_snapshot));
    try encoder.writeInt(u64, message.pane_id);
    try encoder.writeInt(u64, message.known_frame_id);
    return encoder.finish();
}

pub fn encodeDetachPane(buffer: []u8, message: DetachPane) ![]const u8 {
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.detach_pane));
    try encoder.writeInt(u64, message.pane_id);
    return encoder.finish();
}

pub fn encodeRuntimeStop(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.runtime_stop));
    return encoder.finish();
}

pub fn decodeClient(payload: []const u8) !ClientMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeClientTag(try decoder.readByte());
    const message: ClientMessage = switch (tag) {
        .open_pane => .{ .open_pane = try decodeOpenPane(&decoder) },
        .pane_input => .{ .pane_input = try decodePaneInput(&decoder) },
        .pane_resize => .{ .pane_resize = try decodePaneResize(&decoder) },
        .frame_ack => .{ .frame_ack = try decodeFrameAck(&decoder) },
        .request_snapshot => .{ .request_snapshot = try decodeRequestSnapshot(&decoder) },
        .detach_pane => .{ .detach_pane = try decodeDetachPane(&decoder) },
        .runtime_stop => .{ .runtime_stop = {} },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn encodePaneOpened(buffer: []u8, message: PaneOpened) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_opened));
    try encoder.writeInt(u64, message.request_id);
    try encoder.writeInt(u64, message.pane_id);
    try encoder.writeByte(@intFromBool(message.created));
    return encoder.finish();
}

pub fn encodePaneFrame(buffer: []u8, message: frame.Frame) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_frame));
    try frame.encodeBody(&encoder, message);
    return encoder.finish();
}

pub fn encodePaneExited(buffer: []u8, message: PaneExited) ![]const u8 {
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_exited));
    try encoder.writeInt(u64, message.pane_id);
    try encoder.writeByte(@intFromEnum(message.kind));
    try encoder.writeInt(u32, message.value);
    return encoder.finish();
}

pub fn encodeRequestFailed(buffer: []u8, message: RequestFailed) ![]const u8 {
    try validateErrorMessage(message.message);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.request_failed));
    try encoder.writeInt(u64, message.request_id);
    try encoder.writeInt(u16, @intFromEnum(message.code));
    try encoder.writeBytes(message.message);
    return encoder.finish();
}

pub fn encodeRuntimeStopping(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.runtime_stopping));
    return encoder.finish();
}

pub fn decodeServer(payload: []const u8) !ServerMessage {
    var decoder = wire.Decoder.init(payload);
    const tag = try decodeServerTag(try decoder.readByte());
    const message: ServerMessage = switch (tag) {
        .pane_opened => .{ .pane_opened = try decodePaneOpened(&decoder) },
        .pane_frame => .{ .pane_frame = try frame.decodeBody(&decoder) },
        .pane_exited => .{ .pane_exited = try decodePaneExited(&decoder) },
        .request_failed => .{ .request_failed = try decodeRequestFailed(&decoder) },
        .runtime_stopping => .{ .runtime_stopping = {} },
    };
    try decoder.ensureEnd();
    return message;
}

fn encodeLaunch(encoder: *wire.Encoder, launch: Launch) !void {
    try validateBytes(launch.cwd, max_cwd_bytes, false);
    if (launch.arguments.len == 0 or launch.arguments.len > max_argument_count)
        return error.InvalidArgumentCount;
    if (launch.environment.len > max_environment_count)
        return error.TooManyEnvironmentEntries;

    try encoder.writeSized16(launch.cwd);
    try encoder.writeInt(u16, @intCast(launch.arguments.len));
    var argument_bytes: usize = 0;
    for (launch.arguments, 0..) |argument, index| {
        try validateBytes(argument, std.math.maxInt(u16), index != 0);
        argument_bytes = std.math.add(usize, argument_bytes, argument.len) catch
            return error.ArgumentsTooLarge;
        if (argument_bytes > max_argument_bytes) return error.ArgumentsTooLarge;
        try encoder.writeSized16(argument);
    }

    try encoder.writeByte(@intFromEnum(launch.environment_mode));
    try encoder.writeInt(u16, @intCast(launch.environment.len));
    var environment_bytes: usize = 0;
    for (launch.environment) |entry| {
        try validateEnvironmentEntry(entry);
        environment_bytes = std.math.add(usize, environment_bytes, entry.name.len) catch
            return error.EnvironmentTooLarge;
        environment_bytes = std.math.add(usize, environment_bytes, entry.value.len) catch
            return error.EnvironmentTooLarge;
        if (environment_bytes > max_environment_bytes) return error.EnvironmentTooLarge;
        try encoder.writeSized16(entry.name);
        try encoder.writeSized32(entry.value);
    }
}

fn decodeOpenPane(decoder: *wire.Decoder) !OpenPaneView {
    const request_id = try decoder.readInt(u64);
    try validateRequestId(request_id);
    const target_tag = try decoder.readByte();
    const target: PaneTarget = switch (target_tag) {
        0 => .default,
        1 => pane: {
            const pane_id = try decoder.readInt(u64);
            try validatePaneId(pane_id);
            break :pane .{ .pane = pane_id };
        },
        else => return error.InvalidPaneTarget,
    };
    const size = try decodeSize(decoder);
    const launch = switch (target) {
        .default => try decodeLaunch(decoder),
        .pane => null,
    };
    return .{ .request_id = request_id, .target = target, .size = size, .launch = launch };
}

fn decodeLaunch(decoder: *wire.Decoder) !LaunchView {
    const cwd = try decoder.readSized16();
    try validateBytes(cwd, max_cwd_bytes, false);

    const argument_count = try decoder.readInt(u16);
    if (argument_count == 0 or argument_count > max_argument_count)
        return error.InvalidArgumentCount;
    const arguments_start = decoder.index;
    var argument_bytes: usize = 0;
    for (0..argument_count) |index| {
        const argument = try decoder.readSized16();
        try validateBytes(argument, std.math.maxInt(u16), index != 0);
        argument_bytes = std.math.add(usize, argument_bytes, argument.len) catch
            return error.ArgumentsTooLarge;
        if (argument_bytes > max_argument_bytes) return error.ArgumentsTooLarge;
    }
    const encoded_arguments = decoder.consumed(arguments_start);

    const environment_mode = try decodeEnvironmentMode(try decoder.readByte());
    const environment_count = try decoder.readInt(u16);
    if (environment_count > max_environment_count) return error.TooManyEnvironmentEntries;
    const environment_start = decoder.index;
    var environment_bytes: usize = 0;
    for (0..environment_count) |_| {
        const entry = EnvironmentEntry{
            .name = try decoder.readSized16(),
            .value = try decoder.readSized32(),
        };
        try validateEnvironmentEntry(entry);
        environment_bytes = std.math.add(usize, environment_bytes, entry.name.len) catch
            return error.EnvironmentTooLarge;
        environment_bytes = std.math.add(usize, environment_bytes, entry.value.len) catch
            return error.EnvironmentTooLarge;
        if (environment_bytes > max_environment_bytes) return error.EnvironmentTooLarge;
    }
    return .{
        .cwd = cwd,
        .argument_count = argument_count,
        .encoded_arguments = encoded_arguments,
        .environment_mode = environment_mode,
        .environment_count = environment_count,
        .encoded_environment = decoder.consumed(environment_start),
    };
}

fn decodePaneInput(decoder: *wire.Decoder) !PaneInput {
    const pane_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    const bytes = try decoder.readBytes(decoder.bytes.len - decoder.index);
    if (bytes.len == 0 or bytes.len > max_input_bytes) return error.InvalidInputLength;
    return .{ .pane_id = pane_id, .bytes = bytes };
}

fn decodePaneResize(decoder: *wire.Decoder) !PaneResize {
    const pane_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    return .{ .pane_id = pane_id, .size = try decodeSize(decoder) };
}

fn decodeFrameAck(decoder: *wire.Decoder) !FrameAck {
    const pane_id = try decoder.readInt(u64);
    const frame_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    if (frame_id == 0) return error.InvalidFrameId;
    return .{ .pane_id = pane_id, .frame_id = frame_id };
}

fn decodeRequestSnapshot(decoder: *wire.Decoder) !RequestSnapshot {
    const pane_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    return .{
        .pane_id = pane_id,
        .known_frame_id = try decoder.readInt(u64),
    };
}

fn decodeDetachPane(decoder: *wire.Decoder) !DetachPane {
    const pane_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    return .{ .pane_id = pane_id };
}

fn decodePaneOpened(decoder: *wire.Decoder) !PaneOpened {
    const request_id = try decoder.readInt(u64);
    const pane_id = try decoder.readInt(u64);
    try validateRequestId(request_id);
    try validatePaneId(pane_id);
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .created = try decodeBool(try decoder.readByte()),
    };
}

fn decodePaneExited(decoder: *wire.Decoder) !PaneExited {
    const pane_id = try decoder.readInt(u64);
    try validatePaneId(pane_id);
    return .{
        .pane_id = pane_id,
        .kind = try decodeExitKind(try decoder.readByte()),
        .value = try decoder.readInt(u32),
    };
}

fn decodeRequestFailed(decoder: *wire.Decoder) !RequestFailed {
    const request_id = try decoder.readInt(u64);
    const code = try decodeFailureCode(try decoder.readInt(u16));
    const message = try decoder.readBytes(decoder.bytes.len - decoder.index);
    try validateErrorMessage(message);
    return .{ .request_id = request_id, .code = code, .message = message };
}

fn encodeSize(encoder: *wire.Encoder, size: TerminalSize) !void {
    try encoder.writeInt(u16, size.cols);
    try encoder.writeInt(u16, size.rows);
}

fn decodeSize(decoder: *wire.Decoder) !TerminalSize {
    const size = TerminalSize{
        .cols = try decoder.readInt(u16),
        .rows = try decoder.readInt(u16),
    };
    try size.validate();
    return size;
}

fn validateRequestId(request_id: u64) !void {
    if (request_id == 0) return error.InvalidRequestId;
}

fn validatePaneId(pane_id: u64) !void {
    if (pane_id == 0) return error.InvalidPaneId;
}

fn validateBytes(bytes: []const u8, maximum: usize, empty_allowed: bool) !void {
    if ((!empty_allowed and bytes.len == 0) or bytes.len > maximum)
        return error.InvalidByteString;
    if (std.mem.findScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
}

fn validateEnvironmentEntry(entry: EnvironmentEntry) !void {
    try validateBytes(entry.name, std.math.maxInt(u16), false);
    try validateBytes(entry.value, std.math.maxInt(u32), true);
    if (std.mem.findScalar(u8, entry.name, '=') != null) return error.InvalidEnvironmentName;
}

fn validateErrorMessage(message: []const u8) !void {
    if (message.len > max_error_message_bytes) return error.ErrorMessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
}

fn decodeClientTag(value: u8) !ClientTag {
    return switch (value) {
        @intFromEnum(ClientTag.open_pane) => .open_pane,
        @intFromEnum(ClientTag.pane_input) => .pane_input,
        @intFromEnum(ClientTag.pane_resize) => .pane_resize,
        @intFromEnum(ClientTag.frame_ack) => .frame_ack,
        @intFromEnum(ClientTag.request_snapshot) => .request_snapshot,
        @intFromEnum(ClientTag.detach_pane) => .detach_pane,
        @intFromEnum(ClientTag.runtime_stop) => .runtime_stop,
        else => error.UnknownMessage,
    };
}

fn decodeServerTag(value: u8) !ServerTag {
    return switch (value) {
        @intFromEnum(ServerTag.pane_opened) => .pane_opened,
        @intFromEnum(ServerTag.pane_frame) => .pane_frame,
        @intFromEnum(ServerTag.pane_exited) => .pane_exited,
        @intFromEnum(ServerTag.request_failed) => .request_failed,
        @intFromEnum(ServerTag.runtime_stopping) => .runtime_stopping,
        else => error.UnknownMessage,
    };
}

fn decodeEnvironmentMode(value: u8) !EnvironmentMode {
    return switch (value) {
        @intFromEnum(EnvironmentMode.inherit_runtime) => .inherit_runtime,
        @intFromEnum(EnvironmentMode.replace) => .replace,
        else => error.InvalidEnvironmentMode,
    };
}

fn decodeExitKind(value: u8) !ExitKind {
    return switch (value) {
        @intFromEnum(ExitKind.exited) => .exited,
        @intFromEnum(ExitKind.signaled) => .signaled,
        else => error.InvalidExitKind,
    };
}

fn decodeFailureCode(value: u16) !FailureCode {
    return switch (value) {
        @intFromEnum(FailureCode.pane_not_found) => .pane_not_found,
        @intFromEnum(FailureCode.invalid_request) => .invalid_request,
        @intFromEnum(FailureCode.spawn_failed) => .spawn_failed,
        @intFromEnum(FailureCode.permission_denied) => .permission_denied,
        @intFromEnum(FailureCode.resource_limit) => .resource_limit,
        @intFromEnum(FailureCode.internal) => .internal,
        else => error.UnknownFailureCode,
    };
}

fn decodeBool(value: u8) !bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

test "default pane open round trips launch data without allocation" {
    const arguments = [_][]const u8{ "/bin/sh", "-l" };
    const environment = [_]EnvironmentEntry{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "EMPTY", .value = "" },
    };
    const message = OpenPane{
        .request_id = 9,
        .size = .{ .cols = 120, .rows = 40 },
        .launch = .{
            .cwd = "/work",
            .arguments = &arguments,
            .environment_mode = .replace,
            .environment = &environment,
        },
    };

    var buffer: [512]u8 = undefined;
    const decoded = (try decodeClient(try encodeOpenPane(&buffer, message))).open_pane;
    try std.testing.expectEqual(message.request_id, decoded.request_id);
    try std.testing.expect(decoded.target == .default);
    try std.testing.expectEqual(message.size, decoded.size);
    try std.testing.expectEqualStrings("/work", decoded.launch.?.cwd);
    try std.testing.expectEqual(EnvironmentMode.replace, decoded.launch.?.environment_mode);

    var argument_iterator = decoded.launch.?.arguments();
    try std.testing.expectEqualStrings("/bin/sh", argument_iterator.next().?);
    try std.testing.expectEqualStrings("-l", argument_iterator.next().?);
    try std.testing.expect(argument_iterator.next() == null);

    var environment_iterator = decoded.launch.?.environment();
    try std.testing.expectEqualDeep(environment[0], environment_iterator.next().?);
    try std.testing.expectEqualDeep(environment[1], environment_iterator.next().?);
    try std.testing.expect(environment_iterator.next() == null);
}

test "explicit pane attachment has no launch payload" {
    var buffer: [64]u8 = undefined;
    const decoded = (try decodeClient(try encodeOpenPane(&buffer, .{
        .request_id = 2,
        .target = .{ .pane = 41 },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(u64, 41), decoded.target.pane);
    try std.testing.expect(decoded.launch == null);
}

test "fixed client messages round trip" {
    var buffer: [128]u8 = undefined;

    const input = (try decodeClient(try encodePaneInput(&buffer, .{
        .pane_id = 3,
        .bytes = "abc",
    }))).pane_input;
    try std.testing.expectEqual(@as(u64, 3), input.pane_id);
    try std.testing.expectEqualStrings("abc", input.bytes);

    const resize = (try decodeClient(try encodePaneResize(&buffer, .{
        .pane_id = 3,
        .size = .{ .cols = 90, .rows = 30 },
    }))).pane_resize;
    try std.testing.expectEqual(TerminalSize{ .cols = 90, .rows = 30 }, resize.size);

    const ack = (try decodeClient(try encodeFrameAck(&buffer, .{
        .pane_id = 3,
        .frame_id = 8,
    }))).frame_ack;
    try std.testing.expectEqual(@as(u64, 8), ack.frame_id);

    const snapshot = (try decodeClient(try encodeRequestSnapshot(&buffer, .{
        .pane_id = 3,
        .known_frame_id = 7,
    }))).request_snapshot;
    try std.testing.expectEqual(@as(u64, 7), snapshot.known_frame_id);

    const detach = (try decodeClient(try encodeDetachPane(&buffer, .{ .pane_id = 3 }))).detach_pane;
    try std.testing.expectEqual(@as(u64, 3), detach.pane_id);

    try std.testing.expect((try decodeClient(try encodeRuntimeStop(&buffer))) == .runtime_stop);
}

test "fixed server messages round trip" {
    var buffer: [128]u8 = undefined;
    const opened = (try decodeServer(try encodePaneOpened(&buffer, .{
        .request_id = 5,
        .pane_id = 12,
        .created = true,
    }))).pane_opened;
    try std.testing.expect(opened.created);
    try std.testing.expectEqual(@as(u64, 12), opened.pane_id);

    const exited = (try decodeServer(try encodePaneExited(&buffer, .{
        .pane_id = 12,
        .kind = .exited,
        .value = 7,
    }))).pane_exited;
    try std.testing.expectEqual(@as(u32, 7), exited.value);

    const failed = (try decodeServer(try encodeRequestFailed(&buffer, .{
        .request_id = 5,
        .code = .pane_not_found,
        .message = "pane 12 does not exist",
    }))).request_failed;
    try std.testing.expectEqual(FailureCode.pane_not_found, failed.code);
    try std.testing.expectEqualStrings("pane 12 does not exist", failed.message);

    try std.testing.expect((try decodeServer(try encodeRuntimeStopping(&buffer))) == .runtime_stopping);
}

test "pane frames use the server envelope" {
    const cells = [_]@import("../ui.zig").Cell{.{}};
    const spans = [_]frame.Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    const message = frame.Frame{
        .pane_id = 4,
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .spans = &spans,
    };

    const decoded = (try decodeServer(try encodePaneFrame(&buffer, message))).pane_frame;
    try std.testing.expectEqual(@as(u64, 4), decoded.pane_id);
    var span_iterator = decoded.spans();
    var cell_iterator = span_iterator.next().?.cells();
    try std.testing.expectEqualDeep(cells[0], cell_iterator.next().?);
}

test "malformed application messages are rejected" {
    try std.testing.expectError(error.UnknownMessage, decodeClient(&.{0xff}));
    try std.testing.expectError(error.Truncated, decodeClient(&.{@intFromEnum(ClientTag.pane_resize)}));

    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.EmbeddedNul, encodeOpenPane(&buffer, .{
        .request_id = 1,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{"bad\x00argument"},
        },
    }));
    try std.testing.expectError(error.InvalidPaneId, encodePaneInput(&buffer, .{
        .pane_id = 0,
        .bytes = "x",
    }));
}

test "truncated client and server messages are rejected" {
    var client_buffer: [256]u8 = undefined;
    const client_payload = try encodeOpenPane(&client_buffer, .{
        .request_id = 1,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{ "/bin/sh", "-l" },
        },
    });
    for (0..client_payload.len) |length| {
        try std.testing.expectError(error.Truncated, decodeClient(client_payload[0..length]));
    }

    var server_buffer: [128]u8 = undefined;
    const server_payload = try encodePaneOpened(&server_buffer, .{
        .request_id = 1,
        .pane_id = 2,
        .created = true,
    });
    for (0..server_payload.len) |length| {
        try std.testing.expectError(error.Truncated, decodeServer(server_payload[0..length]));
    }
}

test {
    std.testing.refAllDecls(@This());
}
