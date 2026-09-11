const ResourcesType = @import("Resources.zig");
const RegistryType = @import("../Registry.zig");
const PipelineType = @import("../Pipeline.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const ProducerType = @import("../capture/Producer.zig");
const Dependencies = @This();

tls: ResourcesType,
credentials: *RegistryType,
pipeline: *const PipelineType,
transforms: *const TransformPipelineType,
has_custom_transformers: bool,
connection_ids: *std.atomic.Value(u64),
captures: *ProducerType,
