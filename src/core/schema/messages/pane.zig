//! Pane lifecycle, input, output and text messages: everything a client
//! says to or hears from one pane, apart from focus arbitration.

const OpenPane = @import("OpenPane.zig");
const codec = @import("../codec.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const Launch = @import("../Launch.zig");
const launch_mod = @import("launch.zig");
const DecoderType = @import("../Decoder.zig");
const OpenPaneView = @import("OpenPaneView.zig");
const types = @import("../types.zig");
const PaneInput = @import("PaneInput.zig");
const PaneResize = @import("PaneResize.zig");
const FrameAck = @import("FrameAck.zig");
const RequestSnapshot = @import("RequestSnapshot.zig");
const DetachPane = @import("DetachPane.zig");
const CreatePane = @import("CreatePane.zig");
const CreatePaneView = @import("CreatePaneView.zig");
const ClosePane = @import("ClosePane.zig");
const SetPaneViewport = @import("SetPaneViewport.zig");
const ReadPane = @import("ReadPane.zig");
const SendPaneText = @import("SendPaneText.zig");
const std = @import("std");
const SearchPane = @import("SearchPane.zig");
const PaneMatches = @import("PaneMatches.zig");
const PaneMatchesView = @import("PaneMatchesView.zig");
const PaneText = @import("PaneText.zig");
const PaneTitle = @import("PaneTitle.zig");
const CopySelection = @import("CopySelection.zig");
const PaneOpened = @import("PaneOpened.zig");
const FrameType = @import("../Frame.zig");
const frame = @import("../frame_support.zig");
const PaneClipboard = @import("PaneClipboard.zig");
const PaneExited = @import("PaneExited.zig");
const PaneCwd = @import("PaneCwd.zig");
const PaneForeground = @import("PaneForeground.zig");
const PaneProgress = @import("PaneProgress.zig");

pub const max_clipboard_bytes = 64 * 1024;

pub const PaneProgressState = enum(u8) {
    remove,
    set,
    @"error",
    indeterminate,
    pause,
};

pub fn encodeOpenPane(buffer: []u8, message: OpenPane) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try message.size.validate();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.open_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    var default_launch: ?Launch = null;
    switch (message.target) {
        .default => {
            try encoder.writeByte(0);
            default_launch = message.launch orelse return error.MissingLaunch;
        },
        .pane => |pane_id| {
            try codec.validatePaneId(pane_id);
            if (message.launch != null) {
                return error.UnexpectedLaunch;
            }
            try encoder.writeByte(1);
            try encoder.writeInt(u64, id.raw(pane_id));
        },
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) {
                return error.InvalidWorkspaceId;
            }
            if (message.launch != null) {
                return error.UnexpectedLaunch;
            }
            try encoder.writeByte(2);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
    }
    try codec.encodeSize(&encoder, message.size);
    if (default_launch) |launch| {
        try launch_mod.encodeLaunch(&encoder, launch);
    }
    return encoder.finish();
}

pub fn decodeOpenPane(decoder: *DecoderType) !OpenPaneView {
    const request_id = try id.request(try decoder.readInt(u64));
    const target_tag = try decoder.readByte();
    const target: types.PaneTarget = switch (target_tag) {
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
    const size = try codec.decodeSize(decoder);
    const launch = switch (target) {
        .default => try launch_mod.decodeLaunch(decoder),
        .pane, .workspace => null,
    };
    return .{ .request_id = request_id, .target = target, .size = size, .launch = launch };
}

pub fn encodePaneInput(buffer: []u8, message: PaneInput) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    if (message.bytes.len == 0 or message.bytes.len > types.max_input_bytes) {
        return error.InvalidInputLength;
    }

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.pane_input));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeBytes(message.bytes);
    return encoder.finish();
}

pub fn decodePaneInput(decoder: *DecoderType) !PaneInput {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const bytes = try decoder.readBytes(decoder.bytes.len - decoder.index);
    if (bytes.len == 0 or bytes.len > types.max_input_bytes) {
        return error.InvalidInputLength;
    }
    return .{ .pane_id = pane_id, .bytes = bytes };
}

pub fn encodePaneResize(buffer: []u8, message: PaneResize) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.pane_resize), buffer, message);
}

pub fn encodeFrameAck(buffer: []u8, message: FrameAck) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.frame_ack), buffer, message);
}

pub fn encodeRequestSnapshot(buffer: []u8, message: RequestSnapshot) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.request_snapshot), buffer, message);
}

pub fn encodeDetachPane(buffer: []u8, message: DetachPane) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.detach_pane), buffer, message);
}

pub fn encodeCreatePane(buffer: []u8, message: CreatePane) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try message.size.validate();
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.create_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try codec.encodeTabLocation(&encoder, message.location);
    try codec.encodeSize(&encoder, message.size);
    try launch_mod.encodeLaunch(&encoder, message.launch);
    return encoder.finish();
}

pub fn decodeCreatePane(decoder: *DecoderType) !CreatePaneView {
    return .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .location = try codec.decodeTabLocation(decoder),
        .size = try codec.decodeSize(decoder),
        .launch = try launch_mod.decodeLaunch(decoder),
    };
}

pub fn encodeClosePane(buffer: []u8, message: ClosePane) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.close_pane), buffer, message);
}

pub fn encodeSetPaneViewport(buffer: []u8, message: SetPaneViewport) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.set_pane_viewport),
        buffer,
        message,
    );
}

pub fn encodeReadPane(buffer: []u8, message: ReadPane) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.read_pane), buffer, message);
}

pub fn encodeSendPaneText(buffer: []u8, message: SendPaneText) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.text, types.max_pane_text_input_bytes, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.send_pane_text));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.mode));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeSendPaneText(decoder: *DecoderType) !SendPaneText {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const mode = std.enums.fromInt(types.PaneTextMode, try decoder.readByte()) orelse
        return error.InvalidPaneTextMode;
    const text = try decoder.readSized16();
    try codec.validateBytes(text, types.max_pane_text_input_bytes, false);
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .mode = mode,
        .text = text,
    };
}

pub fn encodeSearchPane(buffer: []u8, message: SearchPane) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.needle, types.max_search_needle_bytes, false);
    if (!std.unicode.utf8ValidateSlice(message.needle)) {
        return error.InvalidUtf8;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.search_pane));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.needle);
    return encoder.finish();
}

pub fn decodeSearchPane(decoder: *DecoderType) !SearchPane {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const needle = try decoder.readSized16();
    try codec.validateBytes(needle, types.max_search_needle_bytes, false);
    if (!std.unicode.utf8ValidateSlice(needle)) {
        return error.InvalidUtf8;
    }
    return .{ .request_id = request_id, .pane_id = pane_id, .needle = needle };
}

pub fn encodePaneMatches(buffer: []u8, message: PaneMatches) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    if (message.matches.len > types.max_search_matches) {
        return error.TooManySearchMatches;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_matches));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeInt(u16, @intCast(message.matches.len));
    for (message.matches) |match| {
        if (match.len == 0) {
            return error.InvalidSearchMatch;
        }
        try encoder.writeInt(u16, match.x);
        try encoder.writeInt(u32, match.y);
        try encoder.writeInt(u16, match.len);
    }
    return encoder.finish();
}

pub fn decodePaneMatches(decoder: *DecoderType) !PaneMatchesView {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const truncated = try decoder.readBool();
    const match_count = try decoder.readInt(u16);
    if (match_count > types.max_search_matches) {
        return error.TooManySearchMatches;
    }
    const start = decoder.index;
    for (0..match_count) |_| {
        _ = try decoder.readInt(u16);
        _ = try decoder.readInt(u32);
        if (try decoder.readInt(u16) == 0) {
            return error.InvalidSearchMatch;
        }
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
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    if (message.text.len > types.max_pane_text_bytes) {
        return error.InvalidByteString;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_text));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeSized32(message.text);
    return encoder.finish();
}

pub fn decodePaneText(decoder: *DecoderType) !PaneText {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const truncated = try decoder.readBool();
    const text = try decoder.readSized32();
    if (text.len > types.max_pane_text_bytes) {
        return error.InvalidByteString;
    }
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .truncated = truncated,
        .text = text,
    };
}

pub fn encodePaneTitle(buffer: []u8, message: PaneTitle) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.title, types.max_pane_title_bytes, true);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_title));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.title);
    return encoder.finish();
}

pub fn decodePaneTitle(decoder: *DecoderType) !PaneTitle {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const title = try decoder.readSized16();
    try codec.validateBytes(title, types.max_pane_title_bytes, true);
    return .{ .pane_id = pane_id, .title = title };
}

pub fn encodeCopySelection(buffer: []u8, message: CopySelection) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.copy_selection),
        buffer,
        message,
    );
}

pub fn encodePaneOpened(buffer: []u8, message: PaneOpened) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.pane_opened), buffer, message);
}

pub fn encodePaneFrame(buffer: []u8, message: FrameType) ![]const u8 {
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_frame));
    try frame.encodeBody(&encoder, message);
    return encoder.finish();
}

pub fn encodePaneClipboard(buffer: []u8, message: PaneClipboard) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    if (message.bytes.len > max_clipboard_bytes) {
        return error.ClipboardTooLarge;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_clipboard));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized32(message.bytes);
    return encoder.finish();
}

pub fn decodePaneClipboard(decoder: *DecoderType) !PaneClipboard {
    const clipboard: PaneClipboard = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .bytes = try decoder.readSized32(),
    };
    if (clipboard.bytes.len > max_clipboard_bytes) {
        return error.ClipboardTooLarge;
    }
    return clipboard;
}

pub fn encodePaneExited(buffer: []u8, message: PaneExited) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.pane_exited), buffer, message);
}

pub fn encodePaneCwd(buffer: []u8, message: PaneCwd) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.cwd, types.max_cwd_bytes, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_cwd));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.cwd);
    return encoder.finish();
}

pub fn decodePaneCwd(decoder: *DecoderType) !PaneCwd {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const cwd = try decoder.readSized16();
    try codec.validateBytes(cwd, types.max_cwd_bytes, false);
    return .{ .pane_id = pane_id, .cwd = cwd };
}

pub fn encodePaneForeground(buffer: []u8, message: PaneForeground) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.name, types.max_foreground_name_bytes, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_foreground));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.name);
    return encoder.finish();
}

pub fn decodePaneForeground(decoder: *DecoderType) !PaneForeground {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const name = try decoder.readSized16();
    try codec.validateBytes(name, types.max_foreground_name_bytes, false);
    return .{ .pane_id = pane_id, .name = name };
}

pub fn encodePaneProgress(buffer: []u8, message: PaneProgress) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    try message.validateWire();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_progress));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeByte(@intFromEnum(message.state));
    try encoder.writeByte(message.percent orelse 255);
    return encoder.finish();
}

pub fn decodePaneProgress(decoder: *DecoderType) !PaneProgress {
    const pane_id = try id.pane(try decoder.readInt(u64));
    const state: PaneProgressState = switch (try decoder.readByte()) {
        0 => .remove,
        1 => .set,
        2 => .@"error",
        3 => .indeterminate,
        4 => .pause,
        else => return error.InvalidProgressState,
    };
    const encoded_percent = try decoder.readByte();
    const message: PaneProgress = .{
        .pane_id = pane_id,
        .state = state,
        .percent = if (encoded_percent == 255) null else encoded_percent,
    };
    try message.validateWire();
    return message;
}
