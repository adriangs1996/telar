//! One header rewrite, as data: which heads it matches and the effects it
//! applies to them as one batch.
const header_rules = @import("header_rules.zig");
const RouteMatch = @import("RouteMatch.zig");
const Rewrite = @This();

/// Null matches heads travelling either way.
direction: ?header_rules.Direction = null,
/// Null matches every kind of head.
kind: ?header_rules.HeaderKind = null,
/// Request heads only: the routes it applies to. Null matches any request.
route: ?RouteMatch = null,
effects: []const header_rules.Effect,
