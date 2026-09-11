//! Connection-level messages: runtime lifecycle, subscription to retained
//! runtime state, generic request outcomes and host status.

const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
pub const RequestId = id.RequestId;
pub const FailureCode = types.FailureCode;
pub const ClientIdentity = types.ClientIdentity;
const encodeDerived = codec.encodeDerived;
const validateErrorMessage = codec.validateErrorMessage;
const decodeFailureCode = codec.decodeFailureCode;

pub const ConfigureTerminalColors = types.TerminalColors;

/// Example: `const bytes = try encodeConfigureTerminalColors(&buffer, colors);`.
pub fn encodeConfigureTerminalColors(buffer: []u8, colors: ConfigureTerminalColors) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.configure_terminal_colors));

    for ([_]?[3]u8{ colors.foreground, colors.background }) |color| {
        try encoder.writeByte(@intFromBool(color != null));
        if (color) |rgb| {
            try encoder.writeBytes(&rgb);
        }
    }

    return encoder.finish();
}

/// Example: `const colors = try decodeConfigureTerminalColors(&decoder);`.
pub fn decodeConfigureTerminalColors(decoder: *wire.Decoder) !ConfigureTerminalColors {
    var colors: ConfigureTerminalColors = .{};
    for ([_]*?[3]u8{ &colors.foreground, &colors.background }) |color| {
        if (try decoder.readBool()) {
            color.* = (try decoder.readBytes(3))[0..3].*;
        }
    }

    return colors;
}

pub const RequestRuntimeState = @import("RequestRuntimeState.zig");

pub const RequestFailed = @import("RequestFailed.zig");

pub const RequestCompleted = @import("RequestCompleted.zig");

pub const ProxyStatus = @import("ProxyStatus.zig");

pub const SystemMetrics = @import("SystemMetrics.zig");

pub fn encodeRuntimeStop(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.runtime_stop));
    return encoder.finish();
}

/// Subscribes one stable terminal client to runtime-owned UI state and its
/// in-memory layout snapshot. The subscription lasts until disconnect.
/// Encodes the terminal identity that scopes reconnectable client state.
///
/// ```zig
/// const payload = try encodeRequestRuntimeState(&buffer, request);
/// ```
pub fn encodeRequestRuntimeState(buffer: []u8, message: RequestRuntimeState) ![]const u8 {
    try message.validateWire();
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.request_runtime_state));
    try encoder.writeInt(u64, @intFromEnum(message.client_identity));
    return encoder.finish();
}

pub fn decodeRequestRuntimeState(decoder: *wire.Decoder) !RequestRuntimeState {
    const request: RequestRuntimeState = .{
        .client_identity = @enumFromInt(try decoder.readInt(u64)),
    };
    try request.validateWire();
    return request;
}

pub fn encodeRuntimeStopping(buffer: []u8) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.runtime_stopping));
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

pub fn decodeRequestFailed(decoder: *wire.Decoder) !RequestFailed {
    const request_id: RequestId = @enumFromInt(try decoder.readInt(u64));
    const code = try decodeFailureCode(try decoder.readInt(u16));
    const message = try decoder.readBytes(decoder.bytes.len - decoder.index);
    try validateErrorMessage(message);
    return .{ .request_id = request_id, .code = code, .message = message };
}

pub fn encodeRequestCompleted(buffer: []u8, message: RequestCompleted) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.request_completed), buffer, message);
}

pub fn encodeProxyStatus(buffer: []u8, message: ProxyStatus) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.proxy_status), buffer, message);
}

pub fn encodeSystemMetrics(buffer: []u8, message: SystemMetrics) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.system_metrics), buffer, message);
}
