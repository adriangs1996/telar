const Decoder = @import("Decoder.zig");
const std = @import("std");
const Observed = @import("Observed.zig");
const Capture = @This();

decoder: *Decoder,
text: *std.Io.Writer,
body: []u8,
body_len: *usize,
seen: *Observed,
