//! One header rewrite, as data: which heads it matches and the effects it
//! applies to them as one batch.
const middleware = @import("middleware.zig");
const Rewrite = @This();

/// Null matches heads travelling either way.
direction: ?middleware.Direction = null,
/// Null matches every kind of head.
kind: ?middleware.HeaderKind = null,
/// Request heads only: the method, compared without case. Null matches any.
method: ?[]const u8 = null,
/// Request heads only: paths without their query, compared exactly. Empty
/// matches any path.
paths: []const []const u8 = &.{},
effects: []const middleware.Effect,
