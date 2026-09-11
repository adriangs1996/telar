const std = @import("std");
const TransformPipelineType = @import("../TransformPipeline.zig");
const SessionType = @import("../Session.zig");
const ExchangeType = @import("Exchange.zig");
const ProducerType = @import("../capture/Producer.zig");
const Options = @This();

io: std.Io,
transforms: *const TransformPipelineType,
session: *SessionType,
exchange: *ExchangeType,
captures: ?*ProducerType = null,
