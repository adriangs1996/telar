//! Connection-level messages: runtime lifecycle, subscription to retained
//! runtime state, generic request outcomes and host status.

const TerminalColorsType = @import("../TerminalColors.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const DecoderType = @import("../Decoder.zig");
const RequestRuntimeState = @import("RequestRuntimeState.zig");
const RequestFailed = @import("RequestFailed.zig");
const codec = @import("../codec.zig");
const id = @import("../id.zig");
const RequestCompleted = @import("RequestCompleted.zig");
const ProxyStatus = @import("ProxyStatus.zig");
const SystemMetrics = @import("SystemMetrics.zig");

/// Example: `const bytes = try encodeConfigureTerminalColors(&buffer, colors);`.
pub fn encodeConfigureTerminalColors(buffer: []u8, colors: TerminalColorsType) ![]const u8 {
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.configure_terminal_colors));

    for ([_]?[3]u8{ colors.foreground, colors.background }) |color| {
        try encoder.writeByte(@intFromBool(color != null));
        if (color) |rgb| {
            try encoder.writeBytes(&rgb);
        }
    }

    return encoder.finish();
}

/// Example: `const colors = try decodeConfigureTerminalColors(&decoder);`.
pub fn decodeConfigureTerminalColors(decoder: *DecoderType) !TerminalColorsType {
    var colors: TerminalColorsType = .{};
    for ([_]*?[3]u8{ &colors.foreground, &colors.background }) |color| {
        if (try decoder.readBool()) {
            color.* = (try decoder.readBytes(3))[0..3].*;
        }
    }

    return colors;
}

pub fn encodeRuntimeStop(buffer: []u8) ![]const u8 {
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.runtime_stop));
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
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.request_runtime_state));
    try encoder.writeInt(u64, @intFromEnum(message.client_identity));
    return encoder.finish();
}

pub fn decodeRequestRuntimeState(decoder: *DecoderType) !RequestRuntimeState {
    const request: RequestRuntimeState = .{
        .client_identity = @enumFromInt(try decoder.readInt(u64)),
    };
    try request.validateWire();
    return request;
}

pub fn encodeRuntimeStopping(buffer: []u8) ![]const u8 {
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.runtime_stopping));
    return encoder.finish();
}

pub fn encodeRequestFailed(buffer: []u8, message: RequestFailed) ![]const u8 {
    try codec.validateErrorMessage(message.message);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.request_failed));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intFromEnum(message.code));
    try encoder.writeBytes(message.message);
    return encoder.finish();
}

pub fn decodeRequestFailed(decoder: *DecoderType) !RequestFailed {
    const request_id: id.RequestId = @enumFromInt(try decoder.readInt(u64));
    const code = try codec.decodeFailureCode(try decoder.readInt(u16));
    const message = try decoder.readBytes(decoder.bytes.len - decoder.index);
    try codec.validateErrorMessage(message);
    return .{ .request_id = request_id, .code = code, .message = message };
}

pub fn encodeRequestCompleted(buffer: []u8, message: RequestCompleted) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.request_completed), buffer, message);
}

pub fn encodeProxyStatus(buffer: []u8, message: ProxyStatus) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.proxy_status), buffer, message);
}

pub fn encodeSystemMetrics(buffer: []u8, message: SystemMetrics) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.system_metrics), buffer, message);
}
