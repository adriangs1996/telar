const types = @import("types.zig");
/// Owned metadata derived from one forwarded response head.
const ResponseHead = @This();

/// Valid HTTP status code in the inclusive range 100...599.
status_code: u16,

body: types.BodyPlan,
kind: types.ResponseKind,
connection: types.ConnectionPolicy,
