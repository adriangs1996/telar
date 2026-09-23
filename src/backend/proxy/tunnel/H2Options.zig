const std = @import("std");
const TransformPipeline = @import("../TransformPipeline.zig");
const Session = @import("../Session.zig");
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const Options = @This();

io: std.Io,
gpa: std.mem.Allocator,
transforms: *const TransformPipeline,
has_custom_transformers: bool,
session: *Session,
exchange: *Exchange,
captures: ?*Producer = null,
