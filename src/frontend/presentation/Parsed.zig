const screen_support = @import("screen_support.zig");
const Parsed = @This();

event: screen_support.Event,
/// Bytes consumed. Zero means the input is a prefix of something longer and
/// the caller should read more before trying again.
len: usize,
