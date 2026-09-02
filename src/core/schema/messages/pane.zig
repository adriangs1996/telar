//! Pane lifecycle, input, output and text messages: everything a client
//! says to or hears from one pane, apart from focus arbitration.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const frame = @import("../frame.zig");
const launch_mod = @import("launch.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const TerminalSize = types.TerminalSize;
const PaneTarget = types.PaneTarget;
const TabLocation = types.TabLocation;
const Launch = types.Launch;
const ExitKind = types.ExitKind;
const PaneTextSource = types.PaneTextSource;
const PaneTextMode = types.PaneTextMode;
const SearchMatch = types.SearchMatch;
const LaunchView = launch_mod.LaunchView;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateBytes = codec.validateBytes;
const encodeSize = codec.encodeSize;
const decodeSize = codec.decodeSize;
const encodeTabLocation = codec.encodeTabLocation;
const decodeTabLocation = codec.decodeTabLocation;

pub const max_clipboard_bytes = 64 * 1024;

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

    pub fn validateWire(message: FrameAck) !void {
        if (message.frame_id == 0) return error.InvalidFrameId;
    }
};

pub const RequestSnapshot = struct {
    pane_id: PaneId,
    /// Last frame applied by the client. Zero means it has no pane state.
    known_frame_id: u64,
};

pub const DetachPane = struct {
    pane_id: PaneId,
};

pub const CreatePane = struct {
    request_id: RequestId,
    location: TabLocation,
    size: TerminalSize,
    launch: Launch,
};

pub const CreatePaneView = struct {
    request_id: RequestId,
    location: TabLocation,
    size: TerminalSize,
    launch: LaunchView,
};

pub const ClosePane = struct {
    request_id: RequestId,
    pane_id: PaneId,
};

/// Absolute scrollback row to place at the top of one client attachment.
pub const SetPaneViewport = struct {
    pane_id: PaneId,
    offset: u32,
};

/// Bounded plain-text read of one exact pane generation.
pub const ReadPane = struct {
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    rows: u16,
    source: PaneTextSource,

    pub fn validateWire(message: ReadPane) !void {
        if (message.rows == 0 or message.rows > types.max_pane_text_rows) return error.InvalidPaneTextRows;
    }
};

/// Text delivered to one exact pane generation without a client attachment.
pub const SendPaneText = struct {
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    mode: PaneTextMode,
    text: []const u8,
};

/// Copy-mode text search over one attached pane's retained history.
pub const SearchPane = struct {
    request_id: RequestId,
    pane_id: PaneId,
    needle: []const u8,
};

/// Reply to `search_pane`: every match in document order, at most
/// `max_search_matches`. `truncated` reports that older rows or later
/// matches were not examined.
pub const PaneMatches = struct {
    request_id: RequestId,
    pane_id: PaneId,
    truncated: bool,
    matches: []const SearchMatch,
};

pub const PaneMatchesView = struct {
    request_id: RequestId,
    pane_id: PaneId,
    truncated: bool,
    match_count: u16,
    encoded_matches: []const u8,

    pub fn matches(view: PaneMatchesView) SearchMatchIterator {
        return .{ .decoder = .init(view.encoded_matches), .remaining = view.match_count };
    }
};

pub const SearchMatchIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *SearchMatchIterator) !?SearchMatch {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return .{
            .x = try iterator.decoder.readInt(u16),
            .y = try iterator.decoder.readInt(u32),
            .len = try iterator.decoder.readInt(u16),
        };
    }
};

/// Reply to `read_pane`. `truncated` reports that older rows were omitted to
/// respect `max_pane_text_bytes`.
pub const PaneText = struct {
    request_id: RequestId,
    pane_id: PaneId,
    truncated: bool,
    text: []const u8,
};

/// The child's window title as last set through OSC 0 or OSC 2. An empty
/// title means the child cleared it.
pub const PaneTitle = struct {
    pane_id: PaneId,
    title: []const u8,
};

/// Selection coordinates use the full screen history, not viewport rows.
pub const CopySelection = struct {
    pane_id: PaneId,
    start_x: u16,
    start_y: u32,
    end_x: u16,
    end_y: u32,
    linewise: bool = false,
};

pub const PaneOpened = struct {
    request_id: RequestId,
    pane_id: PaneId,
    location: TabLocation,
    created: bool,
};

pub const PaneExited = struct {
    pane_id: PaneId,
    kind: ExitKind,
    value: u32,
};

pub const PaneCwd = struct {
    pane_id: PaneId,
    cwd: []const u8,
};

pub const PaneForeground = struct {
    pane_id: PaneId,
    name: []const u8,
};

pub const PaneClipboard = struct {
    pane_id: PaneId,
    bytes: []const u8,
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
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) return error.InvalidWorkspaceId;
            if (message.launch != null) return error.UnexpectedLaunch;
            try encoder.writeByte(2);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
    }
    try encodeSize(&encoder, message.size);
    if (default_launch) |launch| try launch_mod.encodeLaunch(&encoder, launch);
    return encoder.finish();
}

pub fn decodeOpenPane(decoder: *wire.Decoder) !OpenPaneView {
    const request_id = try id.request(try decoder.readInt(u64));
    const target_tag = try decoder.readByte();
    const target: PaneTarget = switch (target_tag) {
        0 => .default,
        1 => pane: {
            const pane_id = try id.pane(try decoder.readInt(u64));
            break :pane .{ .pane = pane_id };
        },
        2 => workspace: {
            const workspace_id = try id.workspace(try decoder.readInt(u64));
            break :workspace .{ .workspace = workspace_id };
        },
        else => return error.InvalidPaneTarget,
    };
    const size = try decodeSize(decoder);
    const launch = switch (target) {
        .default => try launch_mod.decodeLaunch(decoder),
        .pane, .workspace => null,
    };
    return .{ .request_id = request_id, .target = target, .size = size, .launch = launch };
}

pub fn encodePaneInput(buffer: []u8, message: PaneInput) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.bytes.len == 0 or message.bytes.len > types.max_input_bytes)
        return error.InvalidInputLength;

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.pane_input));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeBytes(message.bytes);
    return encoder.finish();
}

pub fn decodePaneInput(decoder: *wire.Decoder) !PaneInput {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const bytes = try decoder.readBytes(decoder.bytes.len - decoder.index);
    if (bytes.len == 0 or bytes.len > types.max_input_bytes) return error.InvalidInputLength;
    return .{ .pane_id = pane_id, .bytes = bytes };
}

pub fn encodePaneResize(buffer: []u8, message: PaneResize) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.pane_resize), PaneResize, buffer, message);
}

pub fn encodeFrameAck(buffer: []u8, message: FrameAck) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.frame_ack), FrameAck, buffer, message);
}

pub fn encodeRequestSnapshot(buffer: []u8, message: RequestSnapshot) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.request_snapshot), RequestSnapshot, buffer, message);
}

pub fn encodeDetachPane(buffer: []u8, message: DetachPane) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.detach_pane), DetachPane, buffer, message);
}

pub fn encodeCreatePane(buffer: []u8, message: CreatePane) ![]const u8 {
    try validateRequestId(message.request_id);
    try message.size.validate();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.create_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encodeTabLocation(&encoder, message.location);
    try encodeSize(&encoder, message.size);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreatePane(decoder: *wire.Decoder) !CreatePaneView {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .location = try decodeTabLocation(decoder),
        .size = try decodeSize(decoder),
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeClosePane(buffer: []u8, message: ClosePane) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.close_pane), ClosePane, buffer, message);
}

pub fn encodeSetPaneViewport(buffer: []u8, message: SetPaneViewport) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.set_pane_viewport),
        SetPaneViewport,
        buffer,
        message,
    );
}

pub fn encodeReadPane(buffer: []u8, message: ReadPane) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.read_pane), ReadPane, buffer, message);
}

pub fn encodeSendPaneText(buffer: []u8, message: SendPaneText) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    try validateBytes(message.text, types.max_pane_text_input_bytes, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.send_pane_text));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.mode));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeSendPaneText(decoder: *wire.Decoder) !SendPaneText {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const mode = std.enums.fromInt(PaneTextMode, try decoder.readByte()) orelse
        return error.InvalidPaneTextMode;
    const text = try decoder.readSized16();
    try validateBytes(text, types.max_pane_text_input_bytes, false);
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .mode = mode,
        .text = text,
    };
}

pub fn encodeSearchPane(buffer: []u8, message: SearchPane) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    try validateBytes(message.needle, types.max_search_needle_bytes, false);
    if (!std.unicode.utf8ValidateSlice(message.needle)) return error.InvalidUtf8;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.search_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.needle);
    return encoder.finish();
}

pub fn decodeSearchPane(decoder: *wire.Decoder) !SearchPane {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const needle = try decoder.readSized16();
    try validateBytes(needle, types.max_search_needle_bytes, false);
    if (!std.unicode.utf8ValidateSlice(needle)) return error.InvalidUtf8;
    return .{ .request_id = request_id, .pane_id = pane_id, .needle = needle };
}

pub fn encodePaneMatches(buffer: []u8, message: PaneMatches) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    if (message.matches.len > types.max_search_matches) return error.TooManySearchMatches;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_matches));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeInt(u16, @intCast(message.matches.len));
    for (message.matches) |match| {
        if (match.len == 0) return error.InvalidSearchMatch;
        try encoder.writeInt(u16, match.x);
        try encoder.writeInt(u32, match.y);
        try encoder.writeInt(u16, match.len);
    }
    return encoder.finish();
}

pub fn decodePaneMatches(decoder: *wire.Decoder) !PaneMatchesView {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const truncated = try decoder.readBool();
    const match_count = try decoder.readInt(u16);
    if (match_count > types.max_search_matches) return error.TooManySearchMatches;
    const start = decoder.index;
    for (0..match_count) |_| {
        _ = try decoder.readInt(u16);
        _ = try decoder.readInt(u32);
        if (try decoder.readInt(u16) == 0) return error.InvalidSearchMatch;
    }
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .truncated = truncated,
        .match_count = match_count,
        .encoded_matches = decoder.consumed(start),
    };
}

pub fn encodePaneText(buffer: []u8, message: PaneText) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    if (message.text.len > types.max_pane_text_bytes) return error.InvalidByteString;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_text));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeSized32(message.text);
    return encoder.finish();
}

pub fn decodePaneText(decoder: *wire.Decoder) !PaneText {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const truncated = try decoder.readBool();
    const text = try decoder.readSized32();
    if (text.len > types.max_pane_text_bytes) return error.InvalidByteString;
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .truncated = truncated,
        .text = text,
    };
}

pub fn encodePaneTitle(buffer: []u8, message: PaneTitle) ![]const u8 {
    try validatePaneId(message.pane_id);
    try validateBytes(message.title, types.max_pane_title_bytes, true);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_title));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.title);
    return encoder.finish();
}

pub fn decodePaneTitle(decoder: *wire.Decoder) !PaneTitle {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const title = try decoder.readSized16();
    try validateBytes(title, types.max_pane_title_bytes, true);
    return .{ .pane_id = pane_id, .title = title };
}

pub fn encodeCopySelection(buffer: []u8, message: CopySelection) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.copy_selection),
        CopySelection,
        buffer,
        message,
    );
}

pub fn encodePaneOpened(buffer: []u8, message: PaneOpened) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.pane_opened), PaneOpened, buffer, message);
}

pub fn encodePaneFrame(buffer: []u8, message: frame.Frame) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_frame));
    try frame.encodeBody(&encoder, message);
    return encoder.finish();
}

pub fn encodePaneClipboard(buffer: []u8, message: PaneClipboard) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.bytes.len > max_clipboard_bytes) return error.ClipboardTooLarge;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_clipboard));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized32(message.bytes);
    return encoder.finish();
}

pub fn decodePaneClipboard(decoder: *wire.Decoder) !PaneClipboard {
    const clipboard: PaneClipboard = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .bytes = try decoder.readSized32(),
    };
    if (clipboard.bytes.len > max_clipboard_bytes) return error.ClipboardTooLarge;
    return clipboard;
}

pub fn encodePaneExited(buffer: []u8, message: PaneExited) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.pane_exited), PaneExited, buffer, message);
}

pub fn encodePaneCwd(buffer: []u8, message: PaneCwd) ![]const u8 {
    try validatePaneId(message.pane_id);
    try validateBytes(message.cwd, types.max_cwd_bytes, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_cwd));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.cwd);
    return encoder.finish();
}

pub fn decodePaneCwd(decoder: *wire.Decoder) !PaneCwd {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const cwd = try decoder.readSized16();
    try validateBytes(cwd, types.max_cwd_bytes, false);
    return .{ .pane_id = pane_id, .cwd = cwd };
}

pub fn encodePaneForeground(buffer: []u8, message: PaneForeground) ![]const u8 {
    try validatePaneId(message.pane_id);
    try validateBytes(message.name, types.max_foreground_name_bytes, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_foreground));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.name);
    return encoder.finish();
}

pub fn decodePaneForeground(decoder: *wire.Decoder) !PaneForeground {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const name = try decoder.readSized16();
    try validateBytes(name, types.max_foreground_name_bytes, false);
    return .{ .pane_id = pane_id, .name = name };
}
