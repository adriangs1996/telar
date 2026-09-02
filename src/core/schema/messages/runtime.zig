//! Connection-level messages: runtime lifecycle, subscription to retained
//! runtime state, generic request outcomes and host status.

const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const FailureCode = types.FailureCode;
const ClientIdentity = types.ClientIdentity;
const encodeDerived = codec.encodeDerived;
const validateErrorMessage = codec.validateErrorMessage;
const decodeFailureCode = codec.decodeFailureCode;

pub const RequestRuntimeState = struct {
    client_identity: ClientIdentity,

    /// Rejects identities that cannot own retained runtime state.
    ///
    /// ```zig
    /// try request.validateWire();
    /// ```
    pub fn validateWire(message: RequestRuntimeState) !void {
        if (message.client_identity == .invalid) {
            return error.InvalidClientIdentity;
        }
    }
};

pub const RequestFailed = struct {
    /// Zero identifies a connection-level error rather than a request.
    request_id: RequestId,
    code: FailureCode,
    message: []const u8,
};

/// Reply for requests that succeed without producing data.
pub const RequestCompleted = struct {
    request_id: RequestId,
};

pub const ProxyStatus = struct {
    active: bool,

    pub fn validateWire(message: ProxyStatus) !void {
        _ = message;
    }
};

/// Host health sampled by the runtime, so the client reports the machine the
/// agents actually run on rather than the one showing the UI. Memory is in
/// tenths of a GiB so neither peer formats floating point. A host without a
/// battery reports `has_battery = false` and the client hides the segment.
pub const SystemMetrics = struct {
    revision: u64,
    cpu_percent: u8,
    memory_used_decigib: u16,
    has_battery: bool,
    battery_percent: u8,

    pub fn validateWire(message: SystemMetrics) !void {
        if (message.revision == 0) return error.InvalidMetricsRevision;
        if (message.cpu_percent > 100) return error.InvalidMetricsValue;
        if (message.has_battery and message.battery_percent > 100)
            return error.InvalidMetricsValue;
        if (!message.has_battery and message.battery_percent != 0)
            return error.InvalidMetricsValue;
    }
};

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
    return encodeDerived(@intFromEnum(ServerTag.request_completed), RequestCompleted, buffer, message);
}

pub fn encodeProxyStatus(buffer: []u8, message: ProxyStatus) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.proxy_status), ProxyStatus, buffer, message);
}

pub fn encodeSystemMetrics(buffer: []u8, message: SystemMetrics) ![]const u8 {
    return encodeDerived(@intFromEnum(ServerTag.system_metrics), SystemMetrics, buffer, message);
}
