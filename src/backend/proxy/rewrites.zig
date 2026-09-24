//! Applying header rewrites to one decoded head.
const std = @import("std");
const middleware = @import("middleware.zig");
const Headers = @import("Headers.zig");
const Rewrite = @import("Rewrite.zig");

/// Applies every rewrite that matches `head` to `headers`. Each rewrite's
/// effects apply as one batch: a batch that fails leaves the headers as the
/// previous rewrite left them. Returns whether any batch changed them.
///
/// ```zig
/// const changed = rewrites.apply(request_rewrites, .{ .direction = .request, .kind = .request }, &headers);
/// ```
pub fn apply(rewrites: []const Rewrite, head: Head, headers: *Headers) bool {
    var changed = false;
    for (rewrites) |rewrite| {
        if (!matches(rewrite, head, headers) or rewrite.effects.len == 0) {
            continue;
        }

        var candidate: Headers = undefined;
        candidate.copyFrom(headers);
        candidate.apply(rewrite.effects) catch continue;
        headers.copyFrom(&candidate);
        changed = true;
    }

    return changed;
}

fn matches(rewrite: Rewrite, head: Head, headers: *const Headers) bool {
    if (rewrite.direction) |direction| {
        if (direction != head.direction) {
            return false;
        }
    }

    if (rewrite.kind) |kind| {
        if (kind != head.kind) {
            return false;
        }
    }

    if (rewrite.method) |method| {
        const actual = uniqueValue(headers, ":method") orelse return false;
        if (!std.ascii.eqlIgnoreCase(actual, method)) {
            return false;
        }
    }

    if (rewrite.paths.len == 0) {
        return true;
    }

    const target = uniqueValue(headers, ":path") orelse return false;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    for (rewrite.paths) |wanted| {
        if (std.mem.eql(u8, path, wanted)) {
            return true;
        }
    }

    return false;
}

/// The value of `name` when exactly one field carries it.
fn uniqueValue(headers: *const Headers, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (headers.fields[0..headers.len]) |field| {
        if (!std.ascii.eqlIgnoreCase(headers.name(field), name)) {
            continue;
        }

        if (found != null) {
            return null;
        }

        found = headers.value(field);
    }

    return found;
}

/// Where a head travels and which head it is.
const Head = struct {
    direction: middleware.Direction,
    kind: middleware.HeaderKind,
};

const identity_request: Rewrite = .{
    .direction = .request,
    .kind = .request,
    .method = "POST",
    .paths = &.{"/v1/messages"},
    .effects = &.{.{ .set = .{ .name = "accept-encoding", .value = "identity", .sensitive = false } }},
};

fn requestHeaders(method: []const u8, path: []const u8) !Headers {
    var headers: Headers = .{};
    try headers.append(.{ .name = ":method", .value = method });
    try headers.append(.{ .name = ":path", .value = path });
    try headers.append(.{ .name = "accept-encoding", .value = "gzip" });
    return headers;
}

test "a rewrite applies only to its direction, kind, method and path" {
    var matching = try requestHeaders("post", "/v1/messages?beta=true");
    try std.testing.expect(apply(&.{identity_request}, .{ .direction = .request, .kind = .request }, &matching));
    try std.testing.expectEqualStrings("identity", matching.find("accept-encoding").?);

    var other_path = try requestHeaders("POST", "/v1/messages/count_tokens");
    try std.testing.expect(!apply(&.{identity_request}, .{ .direction = .request, .kind = .request }, &other_path));

    var other_method = try requestHeaders("GET", "/v1/messages");
    try std.testing.expect(!apply(&.{identity_request}, .{ .direction = .request, .kind = .request }, &other_method));

    var response = try requestHeaders("POST", "/v1/messages");
    try std.testing.expect(!apply(&.{identity_request}, .{ .direction = .response, .kind = .response }, &response));
}

test "a duplicated pseudo-header matches no path rewrite" {
    var headers = try requestHeaders("POST", "/v1/messages");
    try headers.append(.{ .name = ":path", .value = "/v1/messages" });
    try std.testing.expect(!apply(&.{identity_request}, .{ .direction = .request, .kind = .request }, &headers));
}

test "a rewrite with more effects than a batch holds leaves the head alone" {
    const effect: middleware.Effect = .{ .set = .{ .name = "x-many", .value = "1", .sensitive = false } };
    const too_many = [_]Rewrite{.{ .effects = &([_]middleware.Effect{effect} ** (middleware.max_effects + 1)) }};
    var headers = try requestHeaders("POST", "/v1/messages");
    try std.testing.expect(!apply(&too_many, .{ .direction = .request, .kind = .request }, &headers));
    try std.testing.expect(headers.find("x-many") == null);
}
