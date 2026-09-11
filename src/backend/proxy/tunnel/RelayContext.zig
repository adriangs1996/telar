const RelayContext = @This();
const source_namespace = @import("h2.zig");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange_support.zig");
const provider = @import("../provider/root.zig");
const capture = @import("../capture/root.zig");
io: source_namespace.Io,
transforms: *const middleware.TransformPipeline,
has_custom_transformers: bool,
session: *tls.Session,
exchange: *exchange_mod.Exchange,
responses: ?*provider.ResponseStreams,
requests: ?*provider.RequestStreams,
captures: ?*capture.Producer = null,
