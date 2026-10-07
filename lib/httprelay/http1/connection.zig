//! HTTP/1.1 exchange concurrency and connection lifecycle.
//!
//! Parsing and byte relay stay behind ports. This module owns when request
//! bodies and responses run concurrently, which observations are published,
//! and whether the intercepted connection is reused, closed, or upgraded.

const ResponseHead = @import("ResponseHead.zig");

pub const ExchangeOutcome = union(enum) {
    complete: ResponseHead,
    early_response: ResponseHead,
    failed,
};

pub const Event = union(enum) {
    request_body: bool,
    response: ?ResponseHead,
};
