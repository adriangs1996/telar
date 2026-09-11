const types = @import("types.zig");
/// Names the deletion being probed for a preview that has no slot yet.
const DeletionProbe = @This();

deletion: types.MarkerDeletion,
policy: types.MarkerPolicy = .ordered,
