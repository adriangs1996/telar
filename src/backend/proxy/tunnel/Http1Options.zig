const Options = @This();
const source_namespace = @import("http1.zig");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange_support.zig");
const capture = @import("../capture/root.zig");
io: source_namespace.Io,
transforms: *const middleware.TransformPipeline,
session: *tls.Session,
exchange: *exchange_mod.Exchange,
captures: ?*capture.Producer = null,
