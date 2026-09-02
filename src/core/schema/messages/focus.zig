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
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const PaneDirection = types.PaneDirection;
const PaneFocusOutcome = types.PaneFocusOutcome;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;

pub const ClientRoute = struct {
    id: u64,
    generation: u64,

    /// Rejects the zero identities reserved for absent client routes.
    ///
    /// ```zig
    /// try route.validateWire();
    /// ```
    pub fn validateWire(route: ClientRoute) !void {
        if (route.id == 0 or route.generation == 0) {
            return error.InvalidClientRoute;
        }
    }
};

pub const RequestPaneFocus = struct {
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    direction: PaneDirection,

    /// Requires an exact live pane identity and a correlatable request.
    ///
    /// ```zig
    /// try request.validateWire();
    /// ```
    pub fn validateWire(request: RequestPaneFocus) !void {
        try validateRequestId(request.request_id);
        try validatePaneId(request.pane_id);
        if (request.pane_generation == 0) {
            return error.InvalidPaneGeneration;
        }
    }
};

pub const CompletePaneFocus = struct {
    requester: ClientRoute,
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    outcome: PaneFocusOutcome,
    focused_pane_id: PaneId,

    /// Validates the echoed route and the focused pane required on success.
    ///
    /// ```zig
    /// try completion.validateWire();
    /// ```
    pub fn validateWire(completion: CompletePaneFocus) !void {
        try completion.requester.validateWire();
        try validateRequestId(completion.request_id);
        try validatePaneId(completion.pane_id);
        if (completion.pane_generation == 0) {
            return error.InvalidPaneGeneration;
        }
        if (completion.outcome == .focused) {
            try validatePaneId(completion.focused_pane_id);
        }
    }
};

pub const PaneFocusCommand = struct {
    requester: ClientRoute,
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    direction: PaneDirection,

    /// Requires the runtime route and exact pane generation sent to the UI.
    ///
    /// ```zig
    /// try command.validateWire();
    /// ```
    pub fn validateWire(command: PaneFocusCommand) !void {
        try command.requester.validateWire();
        try validateRequestId(command.request_id);
        try validatePaneId(command.pane_id);
        if (command.pane_generation == 0) {
            return error.InvalidPaneGeneration;
        }
    }
};

pub const PaneFocusResult = struct {
    request_id: RequestId,
    outcome: PaneFocusOutcome,
    focused_pane_id: PaneId,

    /// Requires a focused pane identity only when the UI changed focus.
    ///
    /// ```zig
    /// try result.validateWire();
    /// ```
    pub fn validateWire(result: PaneFocusResult) !void {
        try validateRequestId(result.request_id);
        if (result.outcome == .focused) {
            try validatePaneId(result.focused_pane_id);
        }
    }
};

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
