const Resources = @import("Resources.zig");
const Registry = @import("../Registry.zig");
const Pipeline = @import("../Pipeline.zig");
const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const Producer = @import("../capture/Producer.zig");
const Dependencies = @This();

tls: Resources,
credentials: *Registry,
pipeline: *const Pipeline,
transforms: *const TransformPipeline,
has_custom_transformers: bool,
connection_ids: *std.atomic.Value(u64),
captures: *Producer,
