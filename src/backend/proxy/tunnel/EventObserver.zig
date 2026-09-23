const Exchange = @import("Exchange.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const CaptureStreams = @import("CaptureStreams.zig");
const relay = @import("../h2/relay.zig");
const h2 = @import("h2.zig");
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

            if (h2.shouldInspectBody(body)) {
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
    if (self.shouldClassifyRequest(lifecycle)) {
        const requests = self.requests.?;
        if (!requests.start(lifecycle.stream_id)) {
            h2.publishRequestClass(self.exchange, lifecycle.stream_id, .auxiliary);
        }

        return;
    }

    if (lifecycle.phase == .request_failed) {
        if (self.requests) |requests| {
            requests.discard(lifecycle.stream_id);
        }
    }

    self.exchange.publishStatus(.{
        .phase = lifecycle.phase,
        .stream_id = lifecycle.stream_id,
        .status_code = lifecycle.status_code,
    });

    if (self.captures) |captures| {
        if (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed) {
            captures.finish(lifecycle.stream_id, if (lifecycle.phase == .response_finished) .finished else .failed);
        }
    }

    if (self.responses) |responses| {
        if (lifecycle.stream_id != 0 and
            (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed))
        {
            responses.finish(lifecycle.stream_id);
        }
    }
}

fn shouldClassifyRequest(self: *const EventObserver, lifecycle: Lifecycle) bool {
    return self.exchange.dialect == .anthropic_messages and self.requests != null and lifecycle.phase == .request_started;
}

fn finishRequest(self: *EventObserver, stream_id: u32) void {
    if (self.captures) |captures| {
        captures.finish(stream_id, .finished);
    }

    const requests = self.requests orelse return;
    const classification = requests.finish(stream_id) orelse return;
    h2.publishRequestClass(self.exchange, stream_id, classification);
}
