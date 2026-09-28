//! The full score tables one positional match fills so it can walk back
//! from the best cell to the bytes that produced it. At 512 KiB it belongs
//! on the heap, reserved once per worker and reused for every candidate.

const std = @import("std");
const Matrix = @This();

pub const max_needle_bytes = 64;
pub const max_haystack_bytes = 1024;

/// Best score of a match that ends by matching needle byte `i` at haystack byte `j`.
ending: [max_needle_bytes][max_haystack_bytes]i32 = undefined,
/// Best score of needle bytes `0..i` placed anywhere inside haystack bytes `0..j`.
best: [max_needle_bytes][max_haystack_bytes]i32 = undefined,

/// Reserves one matrix on the heap.
///
/// ```zig
/// const matrix = try Matrix.create(gpa);
/// defer gpa.destroy(matrix);
/// ```
pub fn create(gpa: std.mem.Allocator) !*Matrix {
    return gpa.create(Matrix);
}
