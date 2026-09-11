const Parsed = @This();
const Event = @import("screen_support.zig").Event;
event: Event,
/// Bytes consumed. Zero means the input is a prefix of something longer and
/// the caller should read more before trying again.
len: usize,
