//! Shell command suggestions answered by the runtime's agent engine.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const SuggestionStatus = types.SuggestionStatus;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateBytes = codec.validateBytes;

/// Asks the runtime's engine for one shell command that fulfils `text` in
/// the context of `pane_id` (its cwd and visible screen).
pub const SuggestCommand = struct {
    request_id: RequestId,
    pane_id: PaneId,
    text: []const u8,
};

/// The engine's answer to `suggest_command`. `text` is empty unless
/// `status == .ready`.
pub const CommandSuggestion = struct {
    request_id: RequestId,
    status: SuggestionStatus,
    text: []const u8 = "",
};

/// Encodes one command-suggestion request.
///
/// ```zig
/// const payload = try encodeSuggestCommand(&buffer, .{ .request_id = id, .pane_id = pane, .text = "list files" });
/// ```
pub fn encodeSuggestCommand(buffer: []u8, message: SuggestCommand) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    try validateBytes(message.text, types.max_suggestion_request_bytes, false);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.suggest_command));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeSuggestCommand(decoder: *wire.Decoder) !SuggestCommand {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const text = try decoder.readSized16();
    try validateBytes(text, types.max_suggestion_request_bytes, false);
    return .{ .request_id = request_id, .pane_id = pane_id, .text = text };
}

/// Encodes one engine reply for a command suggestion.
///
/// ```zig
/// const payload = try encodeCommandSuggestion(&buffer, .{ .request_id = id, .status = .ready, .text = "ls -la" });
/// ```
pub fn encodeCommandSuggestion(buffer: []u8, message: CommandSuggestion) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.text, types.max_suggestion_bytes, true);
    if (message.status != .ready and message.text.len != 0) return error.InvalidSuggestion;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.command_suggestion));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.status));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeCommandSuggestion(decoder: *wire.Decoder) !CommandSuggestion {
    const request_id = try id.request(try decoder.readInt(u64));
    const status = std.enums.fromInt(SuggestionStatus, try decoder.readByte()) orelse return error.InvalidSuggestion;
    const text = try decoder.readSized16();
    try validateBytes(text, types.max_suggestion_bytes, true);
    if (status != .ready and text.len != 0) return error.InvalidSuggestion;
    return .{ .request_id = request_id, .status = status, .text = text };
}
