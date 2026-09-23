const std = @import("std");
const TransformPipeline = @import("../TransformPipeline.zig");
const Session = @import("../Session.zig");
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const Options = @This();

io: std.Io,
transforms: *const TransformPipeline,
session: *Session,
exchange: *Exchange,
captures: ?*Producer = null,
