const DecoderType = @import("Decoder.zig");
const std = @import("std");
const ObservedType = @import("Observed.zig");
const SessionType = @import("Session.zig");
const RouteType = @import("Route.zig");
const h2 = @import("h2.zig");
/// Everything one direction of an h2 connection reported.
const H2Side = @This();

decoder: DecoderType,
text: std.Io.Writer.Allocating,
body: []u8,
body_len: usize = 0,
seen: ObservedType = .{},

pub fn run(self: *H2Side, session: *SessionType, route: RouteType) void {
    h2.relay(session, route, .{
        .decoder = &self.decoder,
        .text = &self.text.writer,
        .body = self.body,
        .body_len = &self.body_len,
        .seen = &self.seen,
    });
    // One side stopping ends the conversation; release the other so the
    // exchange gets recorded instead of waiting on a keep-alive timeout.
    session.halfClose(route.to);
}
