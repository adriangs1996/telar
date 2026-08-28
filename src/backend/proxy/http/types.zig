//! Stable value types exposed by the HTTP proxy namespace.
//!
//! These types own no buffers and borrow no network data. They may outlive the
//! scratch storage used to parse or transform an HTTP message head.

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

/// Why Telar observed the request.
///
/// Classification refers to the request received from the child, before any
/// configured header transformation changes the forwarded method or target.
pub const RequestClass = enum {
    inference,
    auxiliary,
};

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

/// Owned metadata derived from one forwarded request head.
pub const RequestHead = struct {
    classification: RequestClass,
    body: BodyPlan,
    response_context: ResponseContext,
};

/// Owned metadata derived from one forwarded response head.
pub const ResponseHead = struct {
    /// Valid HTTP status code in the inclusive range 100...599.
    status_code: u16,

    body: BodyPlan,
    kind: ResponseKind,
    connection: ConnectionPolicy,
};

test "body plans report whether payload relay is required" {
    try std.testing.expect(!BodyPlan.hasBody(.none));
    try std.testing.expect(!(BodyPlan{ .content_length = 0 }).hasBody());
    try std.testing.expect((BodyPlan{ .content_length = 1 }).hasBody());
    try std.testing.expect(BodyPlan.hasBody(.chunked));
    try std.testing.expect(BodyPlan.hasBody(.until_close));
}
