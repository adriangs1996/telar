//! Per-CONNECT identity and observation state shared by protocol adapters.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");

const Io = std.Io;
const schema = core.schema;

pub const Status = struct {
    phase: middleware.Phase,
    stream_id: u32,
    status_code: u16,
};

pub const TransformTarget = struct {
    direction: middleware.Direction,
    kind: middleware.HeaderKind,
    stream_id: u32,
};

pub const Exchange = struct {
    io: Io,
    pipeline: *const middleware.Pipeline,
    telemetry: *metrics.Counters,
    credential: identity.Credential,
    dialect: provider.ApiDialect,
    connection_id: u64,
    protocol: middleware.Protocol,
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
            .observed_at_ms = Io.Timestamp.now(exchange.io, .real).toMilliseconds(),
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
    pub fn transformContext(exchange: *const Exchange, target: TransformTarget) middleware.TransformContext {
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
};

/// Maps provider request classification to the lifecycle phase shared by
/// HTTP/1.1 and HTTP/2 adapters.
///
/// ```zig
/// const phase = requestPhase(.inference);
/// ```
pub fn requestPhase(classification: provider.RequestClass) middleware.Phase {
    return switch (classification) {
        .inference => .request_started,
        .auxiliary => .auxiliary_request_started,
    };
}

const Capture = struct {
    events: [8]middleware.Event = undefined,
    len: usize = 0,

    fn observe(context: *anyopaque, _: Io, event: middleware.Event) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.events[capture.len] = event;
        capture.len += 1;
    }
};

fn testExchange(pipeline: *const middleware.Pipeline, counters: *metrics.Counters) !Exchange {
    const credential: identity.Credential = .{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 11,
        .token = .{0x42} ** identity.token_bytes,
    };

    return .{
        .io = std.testing.io,
        .pipeline = pipeline,
        .telemetry = counters,
        .credential = credential,
        .dialect = .anthropic_messages,
        .connection_id = 17,
        .protocol = .h2,
    };
}

test "published status carries authenticated exchange identity" {
    var capture: Capture = .{};
    var counters: metrics.Counters = .{};
    var pipeline: middleware.Pipeline = .{};
    try pipeline.add(.{ .context = &capture, .observe = Capture.observe });
    var exchange = try testExchange(&pipeline, &counters);

    exchange.publishStatus(.{
        .phase = .response_finished,
        .stream_id = 19,
        .status_code = 204,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.len);
    const event = capture.events[0];
    try std.testing.expect(std.meta.eql(exchange.credential, event.credential));
    try std.testing.expectEqual(provider.ApiDialect.anthropic_messages, event.dialect);
    try std.testing.expectEqual(middleware.Phase.response_finished, event.phase);
    try std.testing.expectEqual(middleware.Protocol.h2, event.protocol);
    try std.testing.expectEqual(@as(u64, 17), event.connection_id);
    try std.testing.expectEqual(@as(u32, 19), event.stream_id);
    try std.testing.expectEqual(@as(u16, 204), event.status_code);
}

test "only lifecycle evidence for Claude increments Claude counters" {
    var capture: Capture = .{};
    var counters: metrics.Counters = .{};
    var pipeline: middleware.Pipeline = .{};
    try pipeline.add(.{ .context = &capture, .observe = Capture.observe });
    var exchange = try testExchange(&pipeline, &counters);

    inline for (.{
        middleware.Phase.auxiliary_request_started,
        .request_started,
        .response_activity,
        .provider_turn_completed,
        .response_finished,
        .request_failed,
    }) |phase| {
        exchange.publish(phase, 0);
    }

    exchange.record(.claude_sse_payload_fragment);
    const snapshot = counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    });

    try std.testing.expectEqual(@as(u64, 1), snapshot.claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 1), snapshot.claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 1), snapshot.claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 1), snapshot.claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 1), snapshot.claude_failure_observations);

    exchange.dialect = .openai_responses;
    exchange.publish(.request_started, 0);
    try std.testing.expectEqual(@as(u64, 1), counters.snapshot(.{
        .connections = .{ .active = 0, .limit_drops = 0 },
        .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
    }).claude_inference_requests);
}

test "request classification maps to one lifecycle phase" {
    try std.testing.expectEqual(middleware.Phase.request_started, requestPhase(.inference));
    try std.testing.expectEqual(middleware.Phase.auxiliary_request_started, requestPhase(.auxiliary));
}
