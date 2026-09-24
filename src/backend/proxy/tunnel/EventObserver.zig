const std = @import("std");
const middleware = @import("../middleware.zig");
const Exchange = @import("Exchange.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const CaptureStreams = @import("CaptureStreams.zig");
const relay = @import("../h2/relay.zig");
const request_support = @import("../provider/request_support.zig");
const exchange_mod = @import("exchange_support.zig");
const ResponseBody = @import("../h2/ResponseBody.zig");
const Lifecycle = @import("../h2/Lifecycle.zig");
const EventObserver = @This();

exchange: *Exchange,
responses: ?*ResponseStreams = null,
requests: ?*Streams = null,
captures: ?*CaptureStreams = null,

/// Routes borrowed HTTP/2 observations through provider request and
/// response semantics before publishing lifecycle evidence.
///
/// ```zig
/// observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = fragment } });
/// ```
pub fn emit(self: *EventObserver, event: relay.Event) void {
    switch (event) {
        .lifecycle => |lifecycle| self.observeLifecycle(lifecycle),
        .request_headers => |headers| if (self.captures) |captures| captures.feedHeaders(headers),
        .request_body => |body| {
            if (self.captures) |captures| {
                captures.feedBody(body.stream_id, body.bytes);
            }

            const requests = self.requests orelse return;

            requests.feed(.{
                .stream_id = body.stream_id,
                .bytes = body.bytes,
            });
        },
        .request_finished => |finished| self.finishRequest(finished.stream_id),
        .response_headers => |headers| if (self.captures) |captures| captures.feedHeaders(headers),
        .response_body => |body| {
            if (self.captures) |captures| {
                captures.feedBody(body.stream_id, body.bytes);
            }

            const responses = self.responses orelse return;

            if (shouldInspectBody(body)) {
                self.exchange.record(.claude_sse_payload_fragment);

                if (responses.feed(body.stream_id, body.bytes)) {
                    self.exchange.publishStatus(.{
                        .phase = .provider_turn_completed,
                        .stream_id = body.stream_id,
                        .status_code = 0,
                    });
                }
            }
        },
    }
}

fn observeLifecycle(self: *EventObserver, lifecycle: Lifecycle) void {
    const phase = phaseOf(lifecycle);
    if (self.shouldClassifyRequest(phase)) {
        const requests = self.requests.?;
        if (!requests.start(lifecycle.stream_id)) {
            publishRequestClass(self.exchange, lifecycle.stream_id, .auxiliary);
        }

        return;
    }

    if (phase == .request_failed) {
        if (self.requests) |requests| {
            requests.discard(lifecycle.stream_id);
        }
    }

    self.exchange.publishStatus(.{
        .phase = phase,
        .stream_id = lifecycle.stream_id,
        .status_code = lifecycle.status_code,
    });

    if (self.captures) |captures| {
        if (phase == .response_finished or phase == .request_failed) {
            captures.finish(lifecycle.stream_id, if (phase == .response_finished) .finished else .failed);
        }
    }

    if (self.responses) |responses| {
        if (lifecycle.stream_id != 0 and
            (phase == .response_finished or phase == .request_failed))
        {
            responses.finish(lifecycle.stream_id);
        }
    }
}

fn shouldClassifyRequest(self: *const EventObserver, phase: middleware.Phase) bool {
    return self.exchange.dialect == .anthropic_messages and self.requests != null and phase == .request_started;
}

/// The lifecycle phase a relay stage means: a watched request is inference,
/// and a response ending in an error status, a reset stream or a lost
/// connection is a failed request.
fn phaseOf(lifecycle: Lifecycle) middleware.Phase {
    return switch (lifecycle.stage) {
        .request_started => if (lifecycle.watched) .request_started else .auxiliary_request_started,
        .response_activity => .response_activity,
        .response_ended => if (lifecycle.status_code >= 400) .request_failed else .response_finished,
        .stream_reset, .connection_lost => .request_failed,
    };
}

fn finishRequest(self: *EventObserver, stream_id: u32) void {
    if (self.captures) |captures| {
        captures.finish(stream_id, .finished);
    }

    const requests = self.requests orelse return;
    const classification = requests.finish(stream_id) orelse return;
    publishRequestClass(self.exchange, stream_id, classification);
}

fn publishRequestClass(exchange: *Exchange, stream_id: u32, classification: request_support.RequestClass) void {
    exchange.publishStatus(.{
        .phase = exchange_mod.requestPhase(classification),
        .stream_id = stream_id,
        .status_code = 0,
    });
}

fn shouldInspectBody(body: ResponseBody) bool {
    return body.sse_body and body.status_code >= 200 and body.status_code < 300;
}

test "payload inspection requires a successful SSE response body" {
    inline for (.{ @as(u16, 199), 300, 429, 500 }) |status_code| {
        try std.testing.expect(!shouldInspectBody(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    inline for (.{ @as(u16, 200), 204, 299 }) |status_code| {
        try std.testing.expect(shouldInspectBody(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    try std.testing.expect(!shouldInspectBody(.{
        .stream_id = 1,
        .status_code = 200,
        .sse_body = false,
        .bytes = "",
    }));
}

test "relay stages map to lifecycle phases" {
    try std.testing.expectEqual(middleware.Phase.request_started, phaseOf(.{ .stage = .request_started, .stream_id = 1, .status_code = 0, .watched = true }));
    try std.testing.expectEqual(middleware.Phase.auxiliary_request_started, phaseOf(.{ .stage = .request_started, .stream_id = 1, .status_code = 0 }));
    try std.testing.expectEqual(middleware.Phase.response_activity, phaseOf(.{ .stage = .response_activity, .stream_id = 1, .status_code = 200 }));
    try std.testing.expectEqual(middleware.Phase.response_finished, phaseOf(.{ .stage = .response_ended, .stream_id = 1, .status_code = 399 }));
    try std.testing.expectEqual(middleware.Phase.request_failed, phaseOf(.{ .stage = .response_ended, .stream_id = 1, .status_code = 429 }));
    try std.testing.expectEqual(middleware.Phase.request_failed, phaseOf(.{ .stage = .stream_reset, .stream_id = 1, .status_code = 200 }));
    try std.testing.expectEqual(middleware.Phase.request_failed, phaseOf(.{ .stage = .connection_lost, .stream_id = 0, .status_code = 0 }));
}
