const std = @import("std");
const tls = @import("../tls.zig");

pub const max_output_bytes = 64 * 1024;

pub const FakeSession = @import("FakeSession.zig");
