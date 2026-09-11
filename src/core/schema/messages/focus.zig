//! Directional pane focus, arbitrated between a requesting client, the
//! runtime and the client that owns the target pane. Every message carries
//! the exact pane generation so a stale request never moves focus.

const RequestPaneFocus = @import("RequestPaneFocus.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const CompletePaneFocus = @import("CompletePaneFocus.zig");
const PaneFocusCommand = @import("PaneFocusCommand.zig");
const PaneFocusResult = @import("PaneFocusResult.zig");
const DecoderType = @import("../Decoder.zig");
const ClientRoute = @import("ClientRoute.zig");
const types = @import("../types.zig");
const std = @import("std");

pub fn encodeRequestPaneFocus(buffer: []u8, message: RequestPaneFocus) ![]const u8 {
    try message.validateWire();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.request_pane_focus));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.direction));
    return encoder.finish();
}

pub fn encodeCompletePaneFocus(buffer: []u8, message: CompletePaneFocus) ![]const u8 {
    try message.validateWire();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.complete_pane_focus));
    try encodeClientRoute(&encoder, message.requester);
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.outcome));
    try encoder.writeInt(u64, id.raw(message.focused_pane_id));
    return encoder.finish();
}

pub fn encodePaneFocusCommand(buffer: []u8, message: PaneFocusCommand) ![]const u8 {
    try message.validateWire();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_focus_command));
    try encodeClientRoute(&encoder, message.requester);
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.direction));
    return encoder.finish();
}

pub fn encodePaneFocusResult(buffer: []u8, message: PaneFocusResult) ![]const u8 {
    try message.validateWire();

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.pane_focus_result));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.outcome));
    try encoder.writeInt(u64, id.raw(message.focused_pane_id));
    return encoder.finish();
}

pub fn decodeRequestPaneFocus(decoder: *DecoderType) !RequestPaneFocus {
    const request: RequestPaneFocus = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .direction = try decodePaneDirection(decoder),
    };
    try request.validateWire();
    return request;
}

pub fn decodeCompletePaneFocus(decoder: *DecoderType) !CompletePaneFocus {
    const completion: CompletePaneFocus = .{
        .requester = try decodeClientRoute(decoder),
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .outcome = try decodePaneFocusOutcome(decoder),
        .focused_pane_id = @enumFromInt(try decoder.readInt(u64)),
    };
    try completion.validateWire();
    return completion;
}

pub fn decodePaneFocusCommand(decoder: *DecoderType) !PaneFocusCommand {
    const command: PaneFocusCommand = .{
        .requester = try decodeClientRoute(decoder),
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .direction = try decodePaneDirection(decoder),
    };
    try command.validateWire();
    return command;
}

pub fn decodePaneFocusResult(decoder: *DecoderType) !PaneFocusResult {
    const result: PaneFocusResult = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .outcome = try decodePaneFocusOutcome(decoder),
        .focused_pane_id = @enumFromInt(try decoder.readInt(u64)),
    };
    try result.validateWire();
    return result;
}

fn encodeClientRoute(encoder: *EncoderType, route: ClientRoute) !void {
    try route.validateWire();
    try encoder.writeInt(u64, route.id);
    try encoder.writeInt(u64, route.generation);
}

fn decodeClientRoute(decoder: *DecoderType) !ClientRoute {
    const route: ClientRoute = .{
        .id = try decoder.readInt(u64),
        .generation = try decoder.readInt(u64),
    };
    try route.validateWire();
    return route;
}

fn decodePaneDirection(decoder: *DecoderType) !types.PaneDirection {
    return std.enums.fromInt(types.PaneDirection, try decoder.readByte()) orelse return error.InvalidPaneDirection;
}

fn decodePaneFocusOutcome(decoder: *DecoderType) !types.PaneFocusOutcome {
    return std.enums.fromInt(types.PaneFocusOutcome, try decoder.readByte()) orelse return error.InvalidPaneFocusOutcome;
}
