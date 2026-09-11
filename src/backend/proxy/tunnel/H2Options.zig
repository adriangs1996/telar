const std = @import("std");
const TransformPipelineType = @import("../TransformPipeline.zig");
const SessionType = @import("../Session.zig");
const ExchangeType = @import("Exchange.zig");
const ProducerType = @import("../capture/Producer.zig");
const Options = @This();

io: std.Io,
gpa: std.mem.Allocator,
transforms: *const TransformPipelineType,
has_custom_transformers: bool,
session: *SessionType,
exchange: *ExchangeType,
captures: ?*ProducerType = null,
