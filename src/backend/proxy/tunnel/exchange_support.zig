//! Per-CONNECT identity and observation state shared by protocol adapters.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");

pub const Io = std.Io;
const schema = core.schema;
pub const net = Io.net;

pub const Status = @import("Status.zig");

pub const TransformTarget = @import("TransformTarget.zig");

pub const Exchange = @import("Exchange.zig");

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

const Capture = @import("ExchangeCapture.zig");

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
