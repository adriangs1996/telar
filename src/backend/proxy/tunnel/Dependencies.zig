const Dependencies = @This();
const tls_adapter = @import("tls.zig");
const credential_registry = @import("../credential_registry.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
const capture = @import("../capture/root.zig");
tls: tls_adapter.Resources,
credentials: *credential_registry.Registry,
pipeline: *const middleware.Pipeline,
transforms: *const middleware.TransformPipeline,
has_custom_transformers: bool,
connection_ids: *std.atomic.Value(u64),
captures: *capture.Producer,
