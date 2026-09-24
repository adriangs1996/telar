const std = @import("std");
const TransformPipeline = @import("../TransformPipeline.zig");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const Producer = @import("../capture/Producer.zig");
const RelayContext = @This();

io: std.Io,
transforms: *const TransformPipeline,
has_custom_transformers: bool,
session: *Session,
exchange: *Exchange,
responses: ?*ResponseStreams,
requests: ?*Streams,
captures: ?*Producer = null,
