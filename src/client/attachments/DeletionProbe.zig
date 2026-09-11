/// Names the deletion being probed for a preview that has no slot yet.
const DeletionProbe = @This();
const source_namespace = @import("types.zig");
deletion: source_namespace.MarkerDeletion,
policy: source_namespace.MarkerPolicy = .ordered,
