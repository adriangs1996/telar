const EventObserver = @This();
const exchange_mod = @import("exchange_support.zig");
const provider = @import("../provider/root.zig");
const CaptureStreams = @import("CaptureStreams.zig");
const h2 = @import("../h2/root.zig");
const source_namespace = @import("h2.zig");
exchange: *exchange_mod.Exchange,
responses: ?*provider.ResponseStreams = null,
requests: ?*provider.RequestStreams = null,
captures: ?*CaptureStreams = null,

/// Routes borrowed HTTP/2 observations through provider request and
/// response semantics before publishing lifecycle evidence.
///
/// ```zig
/// observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = fragment } });
/// ```
pub fn emit(observer: *EventObserver, event: h2.Event) void {
    switch (event) {
        .lifecycle => |lifecycle| observer.observeLifecycle(lifecycle),
        .request_headers => |headers| if (observer.captures) |captures| captures.feedHeaders(headers),
        .request_body => |body| {
            if (observer.captures) |captures| {
                captures.feedBody(body.stream_id, body.bytes);
            }

            const requests = observer.requests orelse return;

            requests.feed(.{
                .stream_id = body.stream_id,
                .bytes = body.bytes,
            });
        },
        .request_finished => |finished| observer.finishRequest(finished.stream_id),
        .response_headers => |headers| if (observer.captures) |captures| captures.feedHeaders(headers),
        .response_body => |body| {
            if (observer.captures) |captures| {
                captures.feedBody(body.stream_id, body.bytes);
            }

            const responses = observer.responses orelse return;

            if (source_namespace.shouldInspectBody(body)) {
                observer.exchange.record(.claude_sse_payload_fragment);

                if (responses.feed(body.stream_id, body.bytes)) {
                    observer.exchange.publishStatus(.{
                        .phase = .provider_turn_completed,
                        .stream_id = body.stream_id,
                        .status_code = 0,
                    });
                }
            }
        },
    }
}

fn observeLifecycle(observer: *EventObserver, lifecycle: h2.Lifecycle) void {
    if (observer.shouldClassifyRequest(lifecycle)) {
        const requests = observer.requests.?;
        if (!requests.start(lifecycle.stream_id)) {
            source_namespace.publishRequestClass(observer.exchange, lifecycle.stream_id, .auxiliary);
        }

        return;
    }

    if (lifecycle.phase == .request_failed) {
        if (observer.requests) |requests| {
            requests.discard(lifecycle.stream_id);
        }
    }

    observer.exchange.publishStatus(.{
        .phase = lifecycle.phase,
        .stream_id = lifecycle.stream_id,
        .status_code = lifecycle.status_code,
    });

    if (observer.captures) |captures| {
        if (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed) {
            captures.finish(lifecycle.stream_id, if (lifecycle.phase == .response_finished) .finished else .failed);
        }
    }

    if (observer.responses) |responses| {
        if (lifecycle.stream_id != 0 and
            (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed))
        {
            responses.finish(lifecycle.stream_id);
        }
    }
}

fn shouldClassifyRequest(observer: *const EventObserver, lifecycle: h2.Lifecycle) bool {
    return observer.exchange.dialect == .anthropic_messages and observer.requests != null and lifecycle.phase == .request_started;
}

fn finishRequest(observer: *EventObserver, stream_id: u32) void {
    if (observer.captures) |captures| {
        captures.finish(stream_id, .finished);
    }

    const requests = observer.requests orelse return;
    const classification = requests.finish(stream_id) orelse return;
    source_namespace.publishRequestClass(observer.exchange, stream_id, classification);
}
