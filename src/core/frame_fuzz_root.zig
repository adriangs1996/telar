//! Test root of the frame body fuzz target, `zig build test-fuzz-frames-body`.
//! It sits above `schema/` because `frame_support.zig` imports
//! `../text_metadata`, and a module cannot import above its root's directory.
//! No suite imports it, so the coverage build never compiles its fuzz calls.

test {
    _ = @import("schema/frame_fuzz_test.zig");
}
