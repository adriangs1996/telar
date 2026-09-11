/// Owned metadata derived from one forwarded request head.
const RequestHead = @This();
const source_namespace = @import("types.zig");
classification: source_namespace.RequestClass,
body: source_namespace.BodyPlan,
response_context: source_namespace.ResponseContext,
