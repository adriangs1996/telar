//! HTTP/2 for one intercepted CONNECT exchange: the generic relay drives
//! both directions and calls these methods, which install capture streams
//! for the exchange and count decode failures.
const core = @import("telar-core");
const httprelay = @import("httprelay");
const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const h2frames = @import("h2frames");
const Stats = httprelay.http2.Stats;
const CaptureStreams = @import("CaptureStreams.zig");
const EventObserver = @import("EventObserver.zig");
const StreamsInFlight = @import("StreamsInFlight.zig");
const h2 = httprelay.http2;
const relay_module = httprelay.http2;
const GenericConnection = httprelay.http2.GenericConnection;
const RelayContext = @This();

pub const header_block_limit = core.Limit.declare("proxy.h2.max_header_block_bytes", "bytes", h2.max_header_block_bytes);
pub const tracked_streams_limit = core.Limit.declare("proxy.h2.max_tracked_streams", "streams", h2frames.streams.max_tracked_streams);

const RelayConnection = GenericConnection(RelayContext);

io: std.Io,
gpa: std.mem.Allocator,
session: *Session,
exchange: *Exchange,
captures: ?*Producer = null,
/// Streams in flight, shared by both directions' observers.
streams: StreamsInFlight = .{},

/// Relays both directions until the response side ends, then settles.
///
/// ```zig
/// relay_context.run();
/// ```
pub fn run(self: *RelayContext) void {
    RelayConnection.run(self.io, self);
}

/// Relays the request direction through request capture.
///
/// ```zig
/// const stats = relay_context.relayRequest();
/// ```
pub fn relayRequest(self: *RelayContext) Stats {
    return self.relayDirection(.request);
}

/// Relays the response direction through response capture.
///
/// ```zig
/// const stats = relay_context.relayResponse();
/// ```
pub fn relayResponse(self: *RelayContext) Stats {
    return self.relayDirection(.response);
}

fn relayDirection(self: *RelayContext, direction: relay_module.Direction) Stats {
    var captures = if (self.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = self.exchange,
        .side = switch (direction) {
            .request => .request,
            .response => .response,
        },
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .captures = if (captures) |*streams| streams else null,
        .exchange = self.exchange,
        .streams = &self.streams,
    };

    const stats = h2.relay(self.session, h2.relayOptions(direction, .{ .gpa = self.gpa }), &observer);
    self.exchange.enter(.half_closed);

    return stats;
}

/// Counts a direction whose header decoding failed.
///
/// ```zig
/// relay_context.recordDecodeFailure(.request);
/// ```
pub fn recordDecodeFailure(self: *RelayContext, _: relay_module.Direction) void {
    self.exchange.record(.h2_decode_failure);
}

/// Counts the bounds that cut a direction's observation: a header block
/// past `max_header_block_bytes` and streams past the tracked streams.
///
/// ```zig
/// relay_context.recordLimits(.response, stats);
/// ```
pub fn recordLimits(self: *RelayContext, _: relay_module.Direction, stats: Stats) void {
    if (stats.header_block_too_large) {
        self.exchange.record(.h2_header_block_too_large);
    }

    for (0..stats.untracked_streams) |_| {
        self.exchange.record(.h2_stream_untracked);
    }
}

/// Nothing outlives the relay: capture halves end with their streams.
///
/// ```zig
/// relay_context.settle();
/// ```
pub fn settle(self: *RelayContext) void {
    _ = self;
}
