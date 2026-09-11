const OscCapture = @This();
const std = @import("std");
payloads: *std.ArrayList(u8),
ends: *usize,
