//! Directional pane focus, arbitrated between a requesting client, the
//! runtime and the client that owns the target pane. Every message carries
//! the exact pane generation so a stale request never moves focus.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
pub const RequestId = id.RequestId;
pub const PaneId = id.PaneId;
pub const PaneDirection = types.PaneDirection;
pub const PaneFocusOutcome = types.PaneFocusOutcome;
pub const validateRequestId = codec.validateRequestId;
pub const validatePaneId = codec.validatePaneId;

pub const ClientRoute = @import("ClientRoute.zig");

pub const RequestPaneFocus = @import("RequestPaneFocus.zig");

pub const CompletePaneFocus = @import("CompletePaneFocus.zig");

pub const PaneFocusCommand = @import("PaneFocusCommand.zig");

pub const PaneFocusResult = @import("PaneFocusResult.zig");

pub fn encodeRequestPaneFocus(buffer: []u8, message: RequestPaneFocus) ![]const u8 {
    try message.validateWire();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_pane_focus));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.direction));
    return encoder.finish();
}

pub fn encodeCompletePaneFocus(buffer: []u8, message: CompletePaneFocus) ![]const u8 {
    try message.validateWire();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.complete_pane_focus));
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

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_focus_command));
    try encodeClientRoute(&encoder, message.requester);
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.direction));
    return encoder.finish();
}

pub fn encodePaneFocusResult(buffer: []u8, message: PaneFocusResult) ![]const u8 {
    try message.validateWire();

    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.pane_focus_result));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.outcome));
    try encoder.writeInt(u64, id.raw(message.focused_pane_id));
    return encoder.finish();
}

pub fn decodeRequestPaneFocus(decoder: *wire.Decoder) !RequestPaneFocus {
    const request: RequestPaneFocus = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .direction = try decodePaneDirection(decoder),
    };
    try request.validateWire();
    return request;
}

pub fn decodeCompletePaneFocus(decoder: *wire.Decoder) !CompletePaneFocus {
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

pub fn decodePaneFocusCommand(decoder: *wire.Decoder) !PaneFocusCommand {
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

pub fn decodePaneFocusResult(decoder: *wire.Decoder) !PaneFocusResult {
    const result: PaneFocusResult = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .outcome = try decodePaneFocusOutcome(decoder),
        .focused_pane_id = @enumFromInt(try decoder.readInt(u64)),
    };
    try result.validateWire();
    return result;
}

fn encodeClientRoute(encoder: *wire.Encoder, route: ClientRoute) !void {
    try route.validateWire();
    try encoder.writeInt(u64, route.id);
    try encoder.writeInt(u64, route.generation);
}

fn decodeClientRoute(decoder: *wire.Decoder) !ClientRoute {
    const route: ClientRoute = .{
        .id = try decoder.readInt(u64),
        .generation = try decoder.readInt(u64),
    };
    try route.validateWire();
    return route;
}

fn decodePaneDirection(decoder: *wire.Decoder) !PaneDirection {
    return std.enums.fromInt(PaneDirection, try decoder.readByte()) orelse return error.InvalidPaneDirection;
}

fn decodePaneFocusOutcome(decoder: *wire.Decoder) !PaneFocusOutcome {
    return std.enums.fromInt(PaneFocusOutcome, try decoder.readByte()) orelse return error.InvalidPaneFocusOutcome;
}
