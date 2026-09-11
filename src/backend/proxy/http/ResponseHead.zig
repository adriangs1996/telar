/// Owned metadata derived from one forwarded response head.
const ResponseHead = @This();
const source_namespace = @import("types.zig");
/// Valid HTTP status code in the inclusive range 100...599.
status_code: u16,

body: source_namespace.BodyPlan,
kind: source_namespace.ResponseKind,
connection: source_namespace.ConnectionPolicy,
