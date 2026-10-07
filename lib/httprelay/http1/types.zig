//! Stable value types exposed by the HTTP proxy namespace.
//!
//! These types own no buffers and borrow no network data. They may outlive the
//! scratch storage used to parse or transform an HTTP message head.

/// How an HTTP message body is delimited on the wire.
pub const BodyPlan = union(enum) {
    none,
    content_length: usize,
    chunked,
    until_close,

    pub fn hasBody(self: BodyPlan) bool {
        return switch (self) {
            .none => false,
            .content_length => |len| len != 0,
            .chunked, .until_close => true,
        };
    }
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
