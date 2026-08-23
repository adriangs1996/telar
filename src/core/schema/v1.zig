//! Application messages for telar protocol version 2.
//!
//! The handshake selects this schema before either peer calls these decoders.
//! Every function borrows input and caller-owned output memory; none allocates.

const std = @import("std");
const wire = @import("v1/wire.zig");

pub const frame = @import("v1/frame.zig");
pub const id = @import("v1/id.zig");
pub const WorkspaceId = id.WorkspaceId;
pub const WorktreeId = id.WorktreeId;
pub const PaneId = id.PaneId;
pub const RequestId = id.RequestId;

pub const max_input_bytes = 64 * 1024;
pub const max_cwd_bytes = 4096;
pub const max_argument_count = 64;
pub const max_argument_bytes = 128 * 1024;
pub const max_environment_count = 256;
pub const max_environment_bytes = 512 * 1024;
pub const max_error_message_bytes = 1024;
pub const max_panes_per_location = 64;
pub const max_history_query_bytes = 1024;
pub const max_history_results = 100;
pub const max_history_command_bytes = 64 * 1024;

pub const ClientTag = enum(u8) {
    open_pane = 0x01,
    pane_input = 0x02,
    pane_resize = 0x03,
    frame_ack = 0x04,
    request_snapshot = 0x05,
    detach_pane = 0x06,
    runtime_stop = 0x07,
    request_location_snapshot = 0x08,
    create_pane = 0x09,
    close_pane = 0x0a,
    query_history = 0x0b,
};

pub const ServerTag = enum(u8) {
    pane_opened = 0x81,
    pane_frame = 0x82,
    pane_exited = 0x83,
    request_failed = 0x84,
    runtime_stopping = 0x85,
    location_snapshot = 0x86,
    history_results = 0x87,
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
    pane: PaneId,
};

/// Persistent ownership of a pane. A worktree is itself a copy of a
/// workspace, so a pane belongs to exactly one side of this union.
pub const PaneLocation = union(enum) {
    workspace: WorkspaceId,
    worktree: WorktreeId,
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

/// Opens the default pane in the workspace implied by `launch.cwd`, creating
/// it when none exists, or attaches to a specific existing pane. This makes
/// attach-or-create atomic.
pub const OpenPane = struct {
    request_id: RequestId,
    target: PaneTarget = .default,
    size: TerminalSize,
    launch: ?Launch,
};

pub const OpenPaneView = struct {
    request_id: RequestId,
    target: PaneTarget,
    size: TerminalSize,
    launch: ?LaunchView,
};

pub const PaneInput = struct {
    pane_id: PaneId,
    bytes: []const u8,
};

pub const PaneResize = struct {
    pane_id: PaneId,
    size: TerminalSize,
};

pub const FrameAck = struct {
    pane_id: PaneId,
    frame_id: u64,
};

pub const RequestSnapshot = struct {
    pane_id: PaneId,
    /// Last frame applied by the client. Zero means it has no pane state.
    known_frame_id: u64,
};

pub const DetachPane = struct {
    pane_id: PaneId,
};

pub const RequestLocationSnapshot = struct {
    request_id: RequestId,
    location: PaneLocation,
};

pub const CreatePane = struct {
    request_id: RequestId,
    location: PaneLocation,
    size: TerminalSize,
    launch: Launch,
};

pub const CreatePaneView = struct {
    request_id: RequestId,
    location: PaneLocation,
    size: TerminalSize,
    launch: LaunchView,
};

pub const ClosePane = struct {
    request_id: RequestId,
    pane_id: PaneId,
};

pub const HistoryScope = enum(u8) {
    global = 0,
    cwd = 1,
    workspace = 2,
    pane = 3,
};

pub const QueryHistory = struct {
    request_id: RequestId,
    query: []const u8 = "",
    scope: HistoryScope = .global,
    scope_value: []const u8 = "",
    pane_id: PaneId = .invalid,
    failed_only: bool = false,
    limit: u16 = 20,
};

pub const ClientMessage = union(enum) {
    open_pane: OpenPaneView,
    pane_input: PaneInput,
    pane_resize: PaneResize,
    frame_ack: FrameAck,
    request_snapshot: RequestSnapshot,
    detach_pane: DetachPane,
    runtime_stop: void,
    request_location_snapshot: RequestLocationSnapshot,
    create_pane: CreatePaneView,
    close_pane: ClosePane,
    query_history: QueryHistory,
};

pub const PaneOpened = struct {
    request_id: RequestId,
    pane_id: PaneId,
    location: PaneLocation,
    created: bool,
};

pub const ExitKind = enum(u8) {
    exited = 0,
    signaled = 1,
};

pub const PaneExited = struct {
    pane_id: PaneId,
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
    request_id: RequestId,
    code: FailureCode,
    message: []const u8,
};

pub const PaneLifecycle = enum(u8) {
    running = 0,
    exited = 1,
};

pub const PaneDescriptor = struct {
    pane_id: PaneId,
    lifecycle: PaneLifecycle,
};

pub const LocationSnapshot = struct {
    request_id: RequestId,
    location: PaneLocation,
    panes: []const PaneDescriptor,
};

pub const LocationSnapshotView = struct {
    request_id: RequestId,
    location: PaneLocation,
    pane_count: u16,
    encoded_panes: []const u8,

    pub fn panes(snapshot: LocationSnapshotView) PaneDescriptorIterator {
        return .{
            .decoder = .init(snapshot.encoded_panes),
            .remaining = snapshot.pane_count,
        };
    }
};

pub const HistoryStatus = enum(u8) {
    completed = 0,
    interrupted = 1,
};

pub const HistoryEntry = struct {
    id: u64,
    pane_id: PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: HistoryStatus,
    command: []const u8,
    cwd: []const u8,
    workspace_path: []const u8,
};

pub const HistoryResults = struct {
    request_id: RequestId,
    entries: []const HistoryEntry,
};

pub const HistoryResultsView = struct {
    request_id: RequestId,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(results: HistoryResultsView) HistoryEntryIterator {
        return .{
            .decoder = .init(results.encoded_entries),
            .remaining = results.entry_count,
        };
    }
};

pub const HistoryEntryIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *HistoryEntryIterator) ?HistoryEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return decodeHistoryEntry(&iterator.decoder) catch unreachable;
    }
};

pub const PaneDescriptorIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *PaneDescriptorIterator) ?PaneDescriptor {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return .{
            .pane_id = id.pane(iterator.decoder.readInt(u64) catch unreachable) catch unreachable,
            .lifecycle = decodePaneLifecycle(iterator.decoder.readByte() catch unreachable) catch unreachable,
        };
    }
};

pub const ServerMessage = union(enum) {
    pane_opened: PaneOpened,
    pane_frame: frame.FrameView,
    pane_exited: PaneExited,
    request_failed: RequestFailed,
    runtime_stopping: void,
    location_snapshot: LocationSnapshotView,
    history_results: HistoryResultsView,
};

pub fn encodeOpenPane(buffer: []u8, message: OpenPane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.open_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
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
            try encoder.writeInt(u64, id.raw(pane_id));
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
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeBytes(message.bytes);
    return encoder.finish();
}

pub fn encodePaneResize(buffer: []u8, message: PaneResize) ![]const u8 {
    try validatePaneId(message.pane_id);
    try message.size.validate();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.pane_resize));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encodeSize(&encoder, message.size);
    return encoder.finish();
}

pub fn encodeFrameAck(buffer: []u8, message: FrameAck) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.frame_id == 0) return error.InvalidFrameId;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.frame_ack));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.frame_id);
    return encoder.finish();
}

pub fn encodeRequestSnapshot(buffer: []u8, message: RequestSnapshot) ![]const u8 {
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_snapshot));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.known_frame_id);
    return encoder.finish();
}

pub fn encodeDetachPane(buffer: []u8, message: DetachPane) ![]const u8 {
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.detach_pane));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    return encoder.finish();
}

pub fn encodeRequestLocationSnapshot(
    buffer: []u8,
    message: RequestLocationSnapshot,
) ![]const u8 {
    try validateRequestId(message.request_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_location_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodePaneLocation(&encoder, message.location);
    return encoder.finish();
}

pub fn encodeCreatePane(buffer: []u8, message: CreatePane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.create_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodePaneLocation(&encoder, message.location);
    try encodeSize(&encoder, message.size);
    try encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn encodeClosePane(buffer: []u8, message: ClosePane) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.close_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    return encoder.finish();
}

pub fn encodeQueryHistory(buffer: []u8, message: QueryHistory) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.query, max_history_query_bytes, true);
    if (message.limit == 0 or message.limit > max_history_results)
        return error.InvalidHistoryLimit;
    switch (message.scope) {
        .global => if (message.scope_value.len != 0 or message.pane_id != .invalid)
            return error.InvalidHistoryScope,
        .cwd, .workspace => {
            try validateBytes(message.scope_value, max_cwd_bytes, false);
            if (message.pane_id != .invalid) return error.InvalidHistoryScope;
        },
        .pane => {
            try validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) return error.InvalidHistoryScope;
        },
    }
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.query_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.query);
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {},
        .cwd, .workspace => try encoder.writeSized16(message.scope_value),
        .pane => try encoder.writeInt(u64, id.raw(message.pane_id)),
    }
    try encoder.writeByte(@intFromBool(message.failed_only));
    try encoder.writeInt(u16, message.limit);
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
        .request_location_snapshot => .{
            .request_location_snapshot = try decodeRequestLocationSnapshot(&decoder),
        },
        .create_pane => .{ .create_pane = try decodeCreatePane(&decoder) },
        .close_pane => .{ .close_pane = try decodeClosePane(&decoder) },
        .query_history => .{ .query_history = try decodeQueryHistory(&decoder) },
    };
    try decoder.ensureEnd();
    return message;
}

pub fn encodePaneOpened(buffer: []u8, message: PaneOpened) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_opened));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encodePaneLocation(&encoder, message.location);
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
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromEnum(message.kind));
    try encoder.writeInt(u32, message.value);
    return encoder.finish();
}

pub fn encodeRequestFailed(buffer: []u8, message: RequestFailed) ![]const u8 {
    try validateErrorMessage(message.message);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.request_failed));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intFromEnum(message.code));
    try encoder.writeBytes(message.message);
    return encoder.finish();
}

pub fn encodeRuntimeStopping(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.runtime_stopping));
    return encoder.finish();
}

pub fn encodeLocationSnapshot(buffer: []u8, message: LocationSnapshot) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.panes.len > max_panes_per_location) return error.TooManyPanes;

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.location_snapshot));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodePaneLocation(&encoder, message.location);
    try encoder.writeInt(u16, @intCast(message.panes.len));
    for (message.panes, 0..) |pane, pane_index| {
        try validatePaneId(pane.pane_id);
        for (message.panes[0..pane_index]) |previous| {
            if (previous.pane_id == pane.pane_id) return error.DuplicatePane;
        }
        try encoder.writeInt(u64, id.raw(pane.pane_id));
        try encoder.writeByte(@intFromEnum(pane.lifecycle));
    }
    return encoder.finish();
}

pub fn encodeHistoryResults(buffer: []u8, message: HistoryResults) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.entries.len > max_history_results) return error.TooManyHistoryResults;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.history_results));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries) |entry| try encodeHistoryEntry(&encoder, entry);
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
        .location_snapshot => .{
            .location_snapshot = try decodeLocationSnapshot(&decoder),
        },
        .history_results => .{ .history_results = try decodeHistoryResults(&decoder) },
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
    const request_id = try id.request(try decoder.readInt(u64));
    const target_tag = try decoder.readByte();
    const target: PaneTarget = switch (target_tag) {
        0 => .default,
        1 => pane: {
            const pane_id = try id.pane(try decoder.readInt(u64));
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
    const pane_id = try id.pane(try decoder.readInt(u64));
    const bytes = try decoder.readBytes(decoder.bytes.len - decoder.index);
    if (bytes.len == 0 or bytes.len > max_input_bytes) return error.InvalidInputLength;
    return .{ .pane_id = pane_id, .bytes = bytes };
}

fn decodePaneResize(decoder: *wire.Decoder) !PaneResize {
    const pane_id = try id.pane(try decoder.readInt(u64));
    return .{ .pane_id = pane_id, .size = try decodeSize(decoder) };
}

fn decodeFrameAck(decoder: *wire.Decoder) !FrameAck {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const frame_id = try decoder.readInt(u64);
    if (frame_id == 0) return error.InvalidFrameId;
    return .{ .pane_id = pane_id, .frame_id = frame_id };
}

fn decodeRequestSnapshot(decoder: *wire.Decoder) !RequestSnapshot {
    const pane_id = try id.pane(try decoder.readInt(u64));
    return .{
        .pane_id = pane_id,
        .known_frame_id = try decoder.readInt(u64),
    };
}

fn decodeDetachPane(decoder: *wire.Decoder) !DetachPane {
    const pane_id = try id.pane(try decoder.readInt(u64));
    return .{ .pane_id = pane_id };
}

fn decodeRequestLocationSnapshot(decoder: *wire.Decoder) !RequestLocationSnapshot {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .location = try decodePaneLocation(decoder),
    };
}

fn decodeCreatePane(decoder: *wire.Decoder) !CreatePaneView {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .location = try decodePaneLocation(decoder),
        .size = try decodeSize(decoder),
        .launch = try decodeLaunch(decoder),
    };
}

fn decodeClosePane(decoder: *wire.Decoder) !ClosePane {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
    };
}

fn decodeQueryHistory(decoder: *wire.Decoder) !QueryHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const query = try decoder.readSized16();
    try validateBytes(query, max_history_query_bytes, true);
    const scope = try decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try validateBytes(scope_value, max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const failed_only = try decodeBool(try decoder.readByte());
    const limit = try decoder.readInt(u16);
    if (limit == 0 or limit > max_history_results) return error.InvalidHistoryLimit;
    return .{
        .request_id = request_id,
        .query = query,
        .scope = scope,
        .scope_value = scope_value,
        .pane_id = pane_id,
        .failed_only = failed_only,
        .limit = limit,
    };
}

fn decodePaneOpened(decoder: *wire.Decoder) !PaneOpened {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .location = try decodePaneLocation(decoder),
        .created = try decodeBool(try decoder.readByte()),
    };
}

fn decodePaneExited(decoder: *wire.Decoder) !PaneExited {
    const pane_id = try id.pane(try decoder.readInt(u64));
    return .{
        .pane_id = pane_id,
        .kind = try decodeExitKind(try decoder.readByte()),
        .value = try decoder.readInt(u32),
    };
}

fn decodeRequestFailed(decoder: *wire.Decoder) !RequestFailed {
    const request_id: RequestId = @enumFromInt(try decoder.readInt(u64));
    const code = try decodeFailureCode(try decoder.readInt(u16));
    const message = try decoder.readBytes(decoder.bytes.len - decoder.index);
    try validateErrorMessage(message);
    return .{ .request_id = request_id, .code = code, .message = message };
}

fn decodeLocationSnapshot(decoder: *wire.Decoder) !LocationSnapshotView {
    const request_id = try id.request(try decoder.readInt(u64));
    const location = try decodePaneLocation(decoder);
    const pane_count = try decoder.readInt(u16);
    if (pane_count > max_panes_per_location) return error.TooManyPanes;

    const panes_start = decoder.index;
    var seen: [max_panes_per_location]PaneId = undefined;
    for (0..pane_count) |pane_index| {
        const pane_id = try id.pane(try decoder.readInt(u64));
        _ = try decodePaneLifecycle(try decoder.readByte());
        for (seen[0..pane_index]) |previous| {
            if (previous == pane_id) return error.DuplicatePane;
        }
        seen[pane_index] = pane_id;
    }
    return .{
        .request_id = request_id,
        .location = location,
        .pane_count = pane_count,
        .encoded_panes = decoder.consumed(panes_start),
    };
}

fn encodeHistoryEntry(encoder: *wire.Encoder, entry: HistoryEntry) !void {
    if (entry.id == 0) return error.InvalidHistoryId;
    try validatePaneId(entry.pane_id);
    try validateBytes(entry.command, max_history_command_bytes, false);
    try validateBytes(entry.cwd, max_cwd_bytes, false);
    try validateBytes(entry.workspace_path, max_cwd_bytes, false);
    try encoder.writeInt(u64, entry.id);
    try encoder.writeInt(u64, id.raw(entry.pane_id));
    try encoder.writeInt(i64, entry.started_at_ms);
    try encoder.writeInt(i64, entry.duration_ns);
    if (entry.exit_code) |exit_code| {
        try encoder.writeByte(1);
        try encoder.writeInt(i32, exit_code);
    } else {
        try encoder.writeByte(0);
    }
    try encoder.writeByte(@intFromEnum(entry.status));
    try encoder.writeSized32(entry.command);
    try encoder.writeSized16(entry.cwd);
    try encoder.writeSized16(entry.workspace_path);
}

fn decodeHistoryEntry(decoder: *wire.Decoder) !HistoryEntry {
    const history_id = try decoder.readInt(u64);
    if (history_id == 0) return error.InvalidHistoryId;
    const pane_id = try id.pane(try decoder.readInt(u64));
    const started_at_ms = try decoder.readInt(i64);
    const duration_ns = try decoder.readInt(i64);
    const exit_code = if (try decodeBool(try decoder.readByte()))
        try decoder.readInt(i32)
    else
        null;
    const status = try decodeHistoryStatus(try decoder.readByte());
    const command = try decoder.readSized32();
    const cwd = try decoder.readSized16();
    const workspace_path = try decoder.readSized16();
    try validateBytes(command, max_history_command_bytes, false);
    try validateBytes(cwd, max_cwd_bytes, false);
    try validateBytes(workspace_path, max_cwd_bytes, false);
    return .{
        .id = history_id,
        .pane_id = pane_id,
        .started_at_ms = started_at_ms,
        .duration_ns = duration_ns,
        .exit_code = exit_code,
        .status = status,
        .command = command,
        .cwd = cwd,
        .workspace_path = workspace_path,
    };
}

fn decodeHistoryResults(decoder: *wire.Decoder) !HistoryResultsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const entry_count = try decoder.readInt(u16);
    if (entry_count > max_history_results) return error.TooManyHistoryResults;
    const entries_start = decoder.index;
    for (0..entry_count) |_| _ = try decodeHistoryEntry(decoder);
    return .{
        .request_id = request_id,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
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

fn encodePaneLocation(encoder: *wire.Encoder, location: PaneLocation) !void {
    switch (location) {
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) return error.InvalidWorkspaceId;
            try encoder.writeByte(0);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
        .worktree => |worktree_id| {
            if (worktree_id == .invalid) return error.InvalidWorktreeId;
            try encoder.writeByte(1);
            try encoder.writeInt(u64, id.raw(worktree_id));
        },
    }
}

fn decodePaneLocation(decoder: *wire.Decoder) !PaneLocation {
    return switch (try decoder.readByte()) {
        0 => .{ .workspace = try id.workspace(try decoder.readInt(u64)) },
        1 => .{ .worktree = try id.worktree(try decoder.readInt(u64)) },
        else => error.InvalidPaneLocation,
    };
}

fn validateRequestId(request_id: RequestId) !void {
    if (request_id == .none) return error.InvalidRequestId;
}

fn validatePaneId(pane_id: PaneId) !void {
    if (pane_id == .invalid) return error.InvalidPaneId;
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
        @intFromEnum(ClientTag.request_location_snapshot) => .request_location_snapshot,
        @intFromEnum(ClientTag.create_pane) => .create_pane,
        @intFromEnum(ClientTag.close_pane) => .close_pane,
        @intFromEnum(ClientTag.query_history) => .query_history,
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
        @intFromEnum(ServerTag.location_snapshot) => .location_snapshot,
        @intFromEnum(ServerTag.history_results) => .history_results,
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

fn decodePaneLifecycle(value: u8) !PaneLifecycle {
    return switch (value) {
        @intFromEnum(PaneLifecycle.running) => .running,
        @intFromEnum(PaneLifecycle.exited) => .exited,
        else => error.InvalidPaneLifecycle,
    };
}

fn decodeHistoryScope(value: u8) !HistoryScope {
    return switch (value) {
        @intFromEnum(HistoryScope.global) => .global,
        @intFromEnum(HistoryScope.cwd) => .cwd,
        @intFromEnum(HistoryScope.workspace) => .workspace,
        @intFromEnum(HistoryScope.pane) => .pane,
        else => error.InvalidHistoryScope,
    };
}

fn decodeHistoryStatus(value: u8) !HistoryStatus {
    return switch (value) {
        @intFromEnum(HistoryStatus.completed) => .completed,
        @intFromEnum(HistoryStatus.interrupted) => .interrupted,
        else => error.InvalidHistoryStatus,
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
        .request_id = @enumFromInt(9),
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
        .request_id = @enumFromInt(2),
        .target = .{ .pane = @enumFromInt(41) },
        .size = .{ .cols = 80, .rows = 24 },
        .launch = null,
    }))).open_pane;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(41)), decoded.target.pane);
    try std.testing.expect(decoded.launch == null);
}

test "fixed client messages round trip" {
    var buffer: [128]u8 = undefined;

    const input = (try decodeClient(try encodePaneInput(&buffer, .{
        .pane_id = @enumFromInt(3),
        .bytes = "abc",
    }))).pane_input;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(3)), input.pane_id);
    try std.testing.expectEqualStrings("abc", input.bytes);

    const resize = (try decodeClient(try encodePaneResize(&buffer, .{
        .pane_id = @enumFromInt(3),
        .size = .{ .cols = 90, .rows = 30 },
    }))).pane_resize;
    try std.testing.expectEqual(TerminalSize{ .cols = 90, .rows = 30 }, resize.size);

    const ack = (try decodeClient(try encodeFrameAck(&buffer, .{
        .pane_id = @enumFromInt(3),
        .frame_id = 8,
    }))).frame_ack;
    try std.testing.expectEqual(@as(u64, 8), ack.frame_id);

    const snapshot = (try decodeClient(try encodeRequestSnapshot(&buffer, .{
        .pane_id = @enumFromInt(3),
        .known_frame_id = 7,
    }))).request_snapshot;
    try std.testing.expectEqual(@as(u64, 7), snapshot.known_frame_id);

    const detach = (try decodeClient(try encodeDetachPane(&buffer, .{ .pane_id = @enumFromInt(3) }))).detach_pane;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(3)), detach.pane_id);

    try std.testing.expect((try decodeClient(try encodeRuntimeStop(&buffer))) == .runtime_stop);
}

test "multi-pane client messages round trip" {
    var buffer: [512]u8 = undefined;
    const location: PaneLocation = .{ .workspace = @enumFromInt(7) };

    const snapshot = (try decodeClient(try encodeRequestLocationSnapshot(&buffer, .{
        .request_id = @enumFromInt(20),
        .location = location,
    }))).request_location_snapshot;
    try std.testing.expect(std.meta.eql(location, snapshot.location));

    const created = (try decodeClient(try encodeCreatePane(&buffer, .{
        .request_id = @enumFromInt(21),
        .location = location,
        .size = .{ .cols = 60, .rows = 20 },
        .launch = .{ .cwd = "/work", .arguments = &.{ "/bin/sh", "-l" } },
    }))).create_pane;
    try std.testing.expectEqual(@as(u16, 60), created.size.cols);
    try std.testing.expectEqualStrings("/work", created.launch.cwd);

    const closed = (try decodeClient(try encodeClosePane(&buffer, .{
        .request_id = @enumFromInt(22),
        .pane_id = @enumFromInt(8),
    }))).close_pane;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(8)), closed.pane_id);
}

test "history queries round trip with scopes" {
    var buffer: [2048]u8 = undefined;
    const cwd = (try decodeClient(try encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(31),
        .query = "zig build",
        .scope = .cwd,
        .scope_value = "/work/telar",
        .failed_only = true,
        .limit = 12,
    }))).query_history;
    try std.testing.expectEqualStrings("zig build", cwd.query);
    try std.testing.expectEqual(HistoryScope.cwd, cwd.scope);
    try std.testing.expectEqualStrings("/work/telar", cwd.scope_value);
    try std.testing.expect(cwd.failed_only);
    try std.testing.expectEqual(@as(u16, 12), cwd.limit);

    const pane = (try decodeClient(try encodeQueryHistory(&buffer, .{
        .request_id = @enumFromInt(32),
        .scope = .pane,
        .pane_id = @enumFromInt(9),
    }))).query_history;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(9)), pane.pane_id);
}

test "fixed server messages round trip" {
    var buffer: [128]u8 = undefined;
    const opened = (try decodeServer(try encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(5),
        .pane_id = @enumFromInt(12),
        .location = .{ .workspace = @enumFromInt(2) },
        .created = true,
    }))).pane_opened;
    try std.testing.expect(opened.created);
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(12)), opened.pane_id);
    try std.testing.expectEqual(@as(WorkspaceId, @enumFromInt(2)), opened.location.workspace);

    const worktree_opened = (try decodeServer(try encodePaneOpened(&buffer, .{
        .request_id = @enumFromInt(6),
        .pane_id = @enumFromInt(13),
        .location = .{ .worktree = @enumFromInt(3) },
        .created = false,
    }))).pane_opened;
    try std.testing.expectEqual(
        @as(WorktreeId, @enumFromInt(3)),
        worktree_opened.location.worktree,
    );

    const exited = (try decodeServer(try encodePaneExited(&buffer, .{
        .pane_id = @enumFromInt(12),
        .kind = .exited,
        .value = 7,
    }))).pane_exited;
    try std.testing.expectEqual(@as(u32, 7), exited.value);

    const failed = (try decodeServer(try encodeRequestFailed(&buffer, .{
        .request_id = @enumFromInt(5),
        .code = .pane_not_found,
        .message = "pane 12 does not exist",
    }))).request_failed;
    try std.testing.expectEqual(FailureCode.pane_not_found, failed.code);
    try std.testing.expectEqualStrings("pane 12 does not exist", failed.message);

    try std.testing.expect((try decodeServer(try encodeRuntimeStopping(&buffer))) == .runtime_stopping);
}

test "location snapshots preserve ordered pane descriptors" {
    const panes = [_]PaneDescriptor{
        .{ .pane_id = @enumFromInt(3), .lifecycle = .running },
        .{ .pane_id = @enumFromInt(9), .lifecycle = .exited },
    };
    var buffer: [128]u8 = undefined;
    const snapshot = (try decodeServer(try encodeLocationSnapshot(&buffer, .{
        .request_id = @enumFromInt(4),
        .location = .{ .worktree = @enumFromInt(2) },
        .panes = &panes,
    }))).location_snapshot;

    try std.testing.expectEqual(@as(u16, 2), snapshot.pane_count);
    var iterator = snapshot.panes();
    try std.testing.expectEqualDeep(panes[0], iterator.next().?);
    try std.testing.expectEqualDeep(panes[1], iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "history results preserve nullable exits and command metadata" {
    const entries = [_]HistoryEntry{
        .{
            .id = 11,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000000000,
            .duration_ns = 42_000,
            .exit_code = 7,
            .status = .completed,
            .command = "zig build test",
            .cwd = "/work/telar",
            .workspace_path = "/work/telar",
        },
        .{
            .id = 12,
            .pane_id = @enumFromInt(3),
            .started_at_ms = 1700000001000,
            .duration_ns = 9,
            .exit_code = null,
            .status = .interrupted,
            .command = "sleep 600",
            .cwd = "/work/telar",
            .workspace_path = "/work/telar",
        },
    };
    var buffer: [4096]u8 = undefined;
    const results = (try decodeServer(try encodeHistoryResults(&buffer, .{
        .request_id = @enumFromInt(33),
        .entries = &entries,
    }))).history_results;
    try std.testing.expectEqual(@as(u16, 2), results.entry_count);
    var iterator = results.entries();
    try std.testing.expectEqualDeep(entries[0], iterator.next().?);
    try std.testing.expectEqualDeep(entries[1], iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "pane frames use the server envelope" {
    const cells = [_]@import("../ui.zig").Cell{.{}};
    const spans = [_]frame.Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    const message = frame.Frame{
        .pane_id = @enumFromInt(4),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .spans = &spans,
    };

    const decoded = (try decodeServer(try encodePaneFrame(&buffer, message))).pane_frame;
    try std.testing.expectEqual(@as(PaneId, @enumFromInt(4)), decoded.pane_id);
    var span_iterator = decoded.spans();
    var cell_iterator = span_iterator.next().?.cells();
    try std.testing.expectEqualDeep(cells[0], cell_iterator.next().?);
}

test "malformed application messages are rejected" {
    try std.testing.expectError(error.UnknownMessage, decodeClient(&.{0xff}));
    try std.testing.expectError(error.Truncated, decodeClient(&.{@intFromEnum(ClientTag.pane_resize)}));

    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidRequestId, encodeOpenPane(&buffer, .{
        .request_id = .none,
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{ .cwd = "/tmp", .arguments = &.{"/bin/sh"} },
    }));
    try std.testing.expectError(error.EmbeddedNul, encodeOpenPane(&buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 80, .rows = 24 },
        .launch = .{
            .cwd = "/tmp",
            .arguments = &.{"bad\x00argument"},
        },
    }));
    try std.testing.expectError(error.InvalidPaneId, encodePaneInput(&buffer, .{
        .pane_id = .invalid,
        .bytes = "x",
    }));
}

test "truncated client and server messages are rejected" {
    var client_buffer: [256]u8 = undefined;
    const client_payload = try encodeOpenPane(&client_buffer, .{
        .request_id = @enumFromInt(1),
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
        .request_id = @enumFromInt(1),
        .pane_id = @enumFromInt(2),
        .location = .{ .workspace = @enumFromInt(1) },
        .created = true,
    });
    for (0..server_payload.len) |length| {
        try std.testing.expectError(error.Truncated, decodeServer(server_payload[0..length]));
    }
}

test {
    std.testing.refAllDecls(@This());
}
