const std = @import("std");
const PipelineType = @import("../Pipeline.zig");
const CountersType = @import("../Counters.zig");
const CredentialType = @import("../Credential.zig");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");
const Status = @import("Status.zig");
const metrics = @import("../metrics.zig");
const TransformTarget = @import("TransformTarget.zig");
const TransformContextType = @import("../TransformContext.zig");
const Exchange = @This();

io: std.Io,
pipeline: *const PipelineType,
telemetry: *CountersType,
credential: CredentialType,
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
pub fn publish(exchange: *Exchange, phase: middleware.Phase, stream_id: u32) void {
    exchange.publishStatus(.{
        .phase = phase,
        .stream_id = stream_id,
        .status_code = exchange.status_code,
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
pub fn publishStatus(exchange: *Exchange, status: Status) void {
    if (exchange.dialect == .anthropic_messages) {
        const counter: ?metrics.Counter = switch (status.phase) {
            .request_started => .claude_inference_request,
            .provider_turn_completed => .claude_turn_completion,
            .response_finished => .claude_successful_response,
            .request_failed => .claude_failure_observation,
            .auxiliary_request_started, .response_activity => null,
        };

        if (counter) |selected| {
            exchange.telemetry.record(selected);
        }
    }

    exchange.pipeline.publish(exchange.io, .{
        .credential = exchange.credential,
        .dialect = exchange.dialect,
        .phase = status.phase,
        .protocol = exchange.protocol,
        .connection_id = exchange.connection_id,
        .stream_id = status.stream_id,
        .status_code = status.status_code,
        .observed_at_ms = std.Io.Timestamp.now(exchange.io, .real).toMilliseconds(),
    });
}

/// Builds the immutable identity and routing context passed to one header
/// transformation.
///
/// ```zig
/// const context = exchange.transformContext(.{
///     .direction = .request,
///     .kind = .request,
///     .stream_id = 0,
/// });
/// ```
pub fn transformContext(exchange: *const Exchange, target: TransformTarget) TransformContextType {
    return .{
        .pane_id = exchange.credential.pane_id,
        .pane_generation = exchange.credential.pane_generation,
        .dialect = exchange.dialect,
        .protocol = exchange.protocol,
        .direction = target.direction,
        .kind = target.kind,
        .connection_id = exchange.connection_id,
        .stream_id = target.stream_id,
    };
}

/// Records one outcome detected by a protocol adapter.
///
/// ```zig
/// exchange.record(.claude_sse_payload_fragment);
/// ```
pub fn record(exchange: *Exchange, counter: metrics.Counter) void {
    exchange.telemetry.record(counter);
}
