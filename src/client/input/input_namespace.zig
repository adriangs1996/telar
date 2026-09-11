//! Semantic input values independent of host parsing and rendering.

const routing_tests = @import("routing_tests.zig");
const encoding_tests = @import("encoding_tests.zig");
const std = @import("std");

pub const max_encoded_bytes: usize = 8 * 1024;

test {
    _ = routing_tests;
    _ = encoding_tests;
    std.testing.refAllDecls(@This());
}
