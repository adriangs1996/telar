const std = @import("std");
const OscCapture = @This();

payloads: *std.ArrayList(u8),
ends: *usize,
