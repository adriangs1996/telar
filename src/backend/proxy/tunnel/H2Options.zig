const Options = @This();
const source_namespace = @import("h2.zig");
const std = @import("std");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange_support.zig");
const capture = @import("../capture/root.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
transforms: *const middleware.TransformPipeline,
has_custom_transformers: bool,
session: *tls.Session,
exchange: *exchange_mod.Exchange,
captures: ?*capture.Producer = null,
