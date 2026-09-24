//! One header rewrite, as data: which heads it matches and the effects it
//! applies to them as one batch.
const middleware = @import("middleware.zig");
const RouteMatch = @import("RouteMatch.zig");
const Rewrite = @This();

/// Null matches heads travelling either way.
direction: ?middleware.Direction = null,
/// Null matches every kind of head.
kind: ?middleware.HeaderKind = null,
/// Request heads only: the routes it applies to. Null matches any request.
route: ?RouteMatch = null,
effects: []const middleware.Effect,
