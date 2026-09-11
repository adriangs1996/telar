const std = @import("std");
const TransformPipelineType = @import("../TransformPipeline.zig");
const SessionType = @import("../Session.zig");
const ExchangeType = @import("Exchange.zig");
const ResponseStreamsType = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const ProducerType = @import("../capture/Producer.zig");
const RelayContext = @This();

io: std.Io,
transforms: *const TransformPipelineType,
has_custom_transformers: bool,
session: *SessionType,
exchange: *ExchangeType,
responses: ?*ResponseStreamsType,
requests: ?*Streams,
captures: ?*ProducerType = null,
