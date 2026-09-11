//! Shell command suggestions answered by the runtime's agent engine.

const SuggestCommand = @import("SuggestCommand.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const DecoderType = @import("../Decoder.zig");
const CommandSuggestion = @import("CommandSuggestion.zig");
const std = @import("std");

/// Encodes one command-suggestion request.
///
/// ```zig
/// const payload = try encodeSuggestCommand(&buffer, .{ .request_id = id, .pane_id = pane, .text = "list files" });
/// ```
pub fn encodeSuggestCommand(buffer: []u8, message: SuggestCommand) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.text, types.max_suggestion_request_bytes, false);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.suggest_command));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeSuggestCommand(decoder: *DecoderType) !SuggestCommand {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const text = try decoder.readSized16();
    try codec.validateBytes(text, types.max_suggestion_request_bytes, false);
    return .{ .request_id = request_id, .pane_id = pane_id, .text = text };
}

/// Encodes one engine reply for a command suggestion.
///
/// ```zig
/// const payload = try encodeCommandSuggestion(&buffer, .{ .request_id = id, .status = .ready, .text = "ls -la" });
/// ```
pub fn encodeCommandSuggestion(buffer: []u8, message: CommandSuggestion) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.text, types.max_suggestion_bytes, true);
    if (message.status != .ready and message.text.len != 0) {
        return error.InvalidSuggestion;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.command_suggestion));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.status));
    try encoder.writeSized16(message.text);
    return encoder.finish();
}

pub fn decodeCommandSuggestion(decoder: *DecoderType) !CommandSuggestion {
    const request_id = try id.request(try decoder.readInt(u64));
    const status = std.enums.fromInt(types.SuggestionStatus, try decoder.readByte()) orelse return error.InvalidSuggestion;
    const text = try decoder.readSized16();
    try codec.validateBytes(text, types.max_suggestion_bytes, true);
    if (status != .ready and text.len != 0) {
        return error.InvalidSuggestion;
    }
    return .{ .request_id = request_id, .status = status, .text = text };
}
