//! A set of request routes: one method and the paths it applies to,
//! compared without the query.
const std = @import("std");
const RouteMatch = @This();

/// Compared without case.
method: []const u8,
/// Compared exactly, after the query is removed. Empty matches any path.
paths: []const []const u8 = &.{},

/// Whether a request line's method and target fall in this set.
///
/// ```zig
/// if (route.matches("POST", "/v1/messages?beta=true")) watch();
/// ```
pub fn matches(self: RouteMatch, method: []const u8, target: []const u8) bool {
    return self.matchesMethod(method) and self.matchesPath(target);
}

/// Whether `method` is this set's method.
///
/// ```zig
/// if (route.matchesMethod(":method value")) mark();
/// ```
pub fn matchesMethod(self: RouteMatch, method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, self.method);
}

/// Whether a request target's path, without its query, is one of this set's.
///
/// ```zig
/// if (route.matchesPath("/v1/messages?beta=true")) mark();
/// ```
pub fn matchesPath(self: RouteMatch, target: []const u8) bool {
    if (self.paths.len == 0) {
        return true;
    }

    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    for (self.paths) |wanted| {
        if (std.mem.eql(u8, path, wanted)) {
            return true;
        }
    }

    return false;
}

/// Whether any of `routes` matches the request.
///
/// ```zig
/// const watched = RouteMatch.matchesAny(method, target, watched_routes);
/// ```
pub fn matchesAny(method: []const u8, target: []const u8, routes: []const RouteMatch) bool {
    for (routes) |route| {
        if (route.matches(method, target)) {
            return true;
        }
    }

    return false;
}

test "a route matches its method without case and its paths without the query" {
    const route: RouteMatch = .{ .method = "POST", .paths = &.{ "/v1/responses", "/backend-api/codex/responses" } };
    try std.testing.expect(route.matches("post", "/v1/responses"));
    try std.testing.expect(route.matches("POST", "/backend-api/codex/responses?stream=true"));
    try std.testing.expect(!route.matches("GET", "/v1/responses"));
    try std.testing.expect(!route.matches("POST", "/V1/RESPONSES"));
    try std.testing.expect(!route.matches("POST", "/v1/responses#fragment"));
    try std.testing.expect(!RouteMatch.matchesAny("POST", "/v1/responses", &.{}));
}
