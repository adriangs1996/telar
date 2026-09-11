/// Everything one direction of an h2 connection reported.
const H2Side = @This();
const h2 = @import("h2.zig");
const std = @import("std");
const tls = @import("tls.zig");
decoder: h2.Decoder,
text: std.Io.Writer.Allocating,
body: []u8,
body_len: usize = 0,
seen: h2.Observed = .{},

fn run(self: *H2Side, session: *tls.Session, route: h2.Route) void {
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
