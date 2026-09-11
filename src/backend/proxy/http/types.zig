//! Stable value types exposed by the HTTP proxy namespace.
//!
//! These types own no buffers and borrow no network data. They may outlive the
//! scratch storage used to parse or transform an HTTP message head.

const provider = @import("../provider/request_support.zig");
const std = @import("std");

/// How an HTTP message body is delimited on the wire.
pub const BodyPlan = union(enum) {
    none,
    content_length: usize,
    chunked,
    until_close,

    pub fn hasBody(plan: BodyPlan) bool {
        return switch (plan) {
            .none => false,
            .content_length => |len| len != 0,
            .chunked, .until_close => true,
        };
    }
};

pub const RequestClass = provider.RequestClass;

/// Information from the forwarded request needed to parse its response.
pub const ResponseContext = enum {
    normal,
    head_request,
};

/// How the connection loop must handle a parsed response.
pub const ResponseKind = enum {
    informational,
    final,
    upgrade,
};

/// Whether HTTP/1.1 may carry another exchange on the same connection.
pub const ConnectionPolicy = enum {
    keep_alive,
    close,
};

pub const RequestHead = @import("RequestHead.zig");

pub const ResponseHead = @import("ResponseHead.zig");

test "body plans report whether payload relay is required" {
    try std.testing.expect(!BodyPlan.hasBody(.none));
    try std.testing.expect(!(BodyPlan{ .content_length = 0 }).hasBody());
    try std.testing.expect((BodyPlan{ .content_length = 1 }).hasBody());
    try std.testing.expect(BodyPlan.hasBody(.chunked));
    try std.testing.expect(BodyPlan.hasBody(.until_close));
}
