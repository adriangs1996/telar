const host_input = @import("host_input.zig");

event: host_input.Event,
/// Bytes consumed. Zero means the input is a prefix of something longer and
/// the caller should read more before trying again.
len: usize,
