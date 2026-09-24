const std = @import("std");
const Rewrite = @import("../Rewrite.zig");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const Producer = @import("../capture/Producer.zig");
const RelayContext = @This();

io: std.Io,
/// Rewrites applied to request heads; responses keep theirs.
request_rewrites: []const Rewrite,
session: *Session,
exchange: *Exchange,
responses: ?*ResponseStreams,
requests: ?*Streams,
captures: ?*Producer = null,
