//! Bounded, scrubbed storage for one captured exchange part.

pub const max_host_bytes = 255;
pub const max_method_bytes = 32;
pub const max_target_bytes = 8 * 1024;
pub const max_encoding_bytes = 128;

pub const Part = enum {
    request_head,
    request_body,
    response_head,
    response_body,
};

pub const Side = enum {
    request,
    response,
};

pub const Outcome = enum {
    finished,
    failed,
    reset,
};
