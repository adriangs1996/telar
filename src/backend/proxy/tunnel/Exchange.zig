const std = @import("std");
const Channel = @import("../Channel.zig");
const Counters = @import("../Counters.zig");
const Credential = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const metrics = @import("../metrics.zig");
const Exchange = @This();

io: std.Io,
observations: *Channel,
telemetry: *Counters,
credential: Credential,
dialect: types.ApiDialect,
connection_id: u64,
protocol: middleware.Protocol,
host: std.Io.net.HostName = undefined,
status_code: u16 = 0,

/// Publishes one lifecycle phase for the current status and stream.
///
/// ```zig
/// exchange.publish(.response_activity, 0);
/// ```
pub fn publish(self: *Exchange, phase: middleware.Phase, stream_id: u32) void {
    self.publishStatus(.{
        .phase = phase,
        .stream_id = stream_id,
        .status_code = self.status_code,
    });
}

/// Records provider counters and publishes one complete observation with
/// the authenticated identity of this CONNECT exchange.
///
/// ```zig
/// exchange.publishStatus(.{
///     .phase = .response_finished,
///     .stream_id = 3,
///     .status_code = 200,
/// });
/// ```
pub fn publishStatus(self: *Exchange, status: Status) void {
    if (self.dialect == .anthropic_messages) {
        const counter: ?metrics.Counter = switch (status.phase) {
            .request_started => .claude_inference_request,
            .provider_turn_completed => .claude_turn_completion,
            .response_finished => .claude_successful_response,
            .request_failed => .claude_failure_observation,
            .auxiliary_request_started, .response_activity => null,
        };

        if (counter) |selected| {
            self.telemetry.record(selected);
        }
    }

    self.observations.publish(self.io, .{
        .credential = self.credential,
        .dialect = self.dialect,
        .phase = status.phase,
        .protocol = self.protocol,
        .connection_id = self.connection_id,
        .stream_id = status.stream_id,
        .status_code = status.status_code,
        .observed_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
    });
}

/// Records one outcome detected by a protocol adapter.
///
/// ```zig
/// exchange.record(.claude_sse_payload_fragment);
/// ```
pub fn record(self: *Exchange, counter: metrics.Counter) void {
    self.telemetry.record(counter);
}

const Status = struct {
    phase: middleware.Phase,
    stream_id: u32,
    status_code: u16,
};
