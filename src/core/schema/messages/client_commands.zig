const std = @import("std");
const Encoder = @import("../Encoder.zig");
const Decoder = @import("../Decoder.zig");
const id = @import("../id.zig");
const tags = @import("tags.zig");
const actions = @import("client_actions.zig");
const ClientCommand = @import("ClientCommand.zig");

fn encode(buffer: []u8, message: ClientCommand, tag: u8) ![]const u8 {
    try message.validateWire();
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(tag);
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, message.route.id);
    try encoder.writeInt(u64, message.route.generation);
    try encoder.writeByte(@intFromEnum(message.action));
    try encoder.writeByte(@intFromEnum(message.status));
    try encoder.writeInt(u64, message.target_id);
    try encoder.writeInt(i64, message.value);
    try encoder.writeSized16(message.text());
    return encoder.finish();
}

/// Decodes into owned bounded storage. Example: `const message = try client_commands.decode(decoder);`
pub fn decode(decoder: *Decoder) !ClientCommand {
    var message: ClientCommand = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .route = .{ .id = try decoder.readInt(u64), .generation = try decoder.readInt(u64) },
        .action = std.enums.fromInt(actions.Action, try decoder.readByte()) orelse return error.InvalidClientAction,
        .status = std.enums.fromInt(actions.Status, try decoder.readByte()) orelse return error.InvalidClientCommandStatus,
        .target_id = try decoder.readInt(u64),
        .value = try decoder.readInt(i64),
    };
    try message.setText(try decoder.readSized16());
    try message.validateWire();
    return message;
}

/// Encodes one correlated exchange. Example: `const bytes = try client_commands.encodeRequestClientCommand(buffer, message);`
pub fn encodeRequestClientCommand(buffer: []u8, message: ClientCommand) ![]const u8 {
    return encode(buffer, message, @intFromEnum(tags.ClientTag.request_client_command));
}

/// Encodes one correlated exchange. Example: `const bytes = try client_commands.encodeCompleteClientCommand(buffer, message);`
pub fn encodeCompleteClientCommand(buffer: []u8, message: ClientCommand) ![]const u8 {
    return encode(buffer, message, @intFromEnum(tags.ClientTag.complete_client_command));
}

/// Encodes one correlated exchange. Example: `const bytes = try client_commands.encodeClientCommand(buffer, message);`
pub fn encodeClientCommand(buffer: []u8, message: ClientCommand) ![]const u8 {
    return encode(buffer, message, @intFromEnum(tags.ServerTag.client_command));
}

/// Encodes one correlated exchange. Example: `const bytes = try client_commands.encodeClientCommandResult(buffer, message);`
pub fn encodeClientCommandResult(buffer: []u8, message: ClientCommand) ![]const u8 {
    return encode(buffer, message, @intFromEnum(tags.ServerTag.client_command_result));
}
