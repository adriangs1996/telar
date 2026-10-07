//! Routes borrowed HTTP/2 relay events into exchange capture: heads and
//! de-framed body fragments feed the stream's half, and each stream's end
//! finishes it with the outcome its stage means.
const exchangecapture = @import("exchangecapture");
const httprelay = @import("httprelay");
const CaptureStreams = @import("CaptureStreams.zig");
const Exchange = @import("Exchange.zig");
const StreamsInFlight = @import("StreamsInFlight.zig");
const relay = httprelay.http2;
const buffer_support = exchangecapture.buffer_support;
const Lifecycle = httprelay.http2.Lifecycle;
const EventObserver = @This();

captures: ?*CaptureStreams = null,
/// The connection whose activity and streams in flight the relay reports;
/// null in tests.
exchange: ?*Exchange = null,
/// The connection's streams in flight, shared by both directions.
streams: ?*StreamsInFlight = null,

/// Example: `observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = fragment } });`
pub fn emit(self: *EventObserver, event: relay.Event) void {
    self.countStream(event);

    const captures = self.captures orelse return;
    switch (event) {
        .lifecycle => |lifecycle| if (outcomeOf(lifecycle)) |outcome| {
            captures.finish(lifecycle.stream_id, outcome);
        },
        .request_headers, .response_headers => |headers| captures.feedHeaders(headers),
        .request_body => |body| captures.feedBody(body.stream_id, body.bytes),
        .response_body => |body| captures.feedBody(body.stream_id, body.bytes),
        .request_finished => |finished| captures.finish(finished.stream_id, .finished),
    }
}

/// Every read the relay forwards marks the connection active, frames that
/// publish no event, such as PING and WINDOW_UPDATE, included.
///
/// ```zig
/// observer.relayed();
/// ```
pub fn relayed(self: *EventObserver) void {
    const exchange = self.exchange orelse return;
    exchange.touch();
}

/// A started stream is an exchange in flight until its first end or reset;
/// an end of a stream that never counted, or a second end, changes nothing.
fn countStream(self: *EventObserver, event: relay.Event) void {
    const exchange = self.exchange orelse return;
    const streams = self.streams orelse return;
    const lifecycle = switch (event) {
        .lifecycle => |value| value,
        else => return,
    };

    switch (lifecycle.stage) {
        .request_started => if (streams.start(lifecycle.stream_id)) {
            exchange.beginExchange();
        },
        .response_ended, .stream_reset => if (streams.end(lifecycle.stream_id)) {
            exchange.endExchange();
        },
        .response_activity, .connection_lost => {},
    }
}

/// The capture outcome a relay stage ends a stream with: a response with an
/// error status, a reset stream or a lost connection failed; a completed
/// response finished; other stages end nothing.
fn outcomeOf(lifecycle: Lifecycle) ?buffer_support.Outcome {
    return switch (lifecycle.stage) {
        .request_started, .response_activity => null,
        .response_ended => if (lifecycle.status_code >= 400) .failed else .finished,
        .stream_reset, .connection_lost => .failed,
    };
}
