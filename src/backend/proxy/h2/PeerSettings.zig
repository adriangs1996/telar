const PeerSettings = @This();
const std = @import("std");
header_table_size: std.atomic.Value(u32) = .init(4096),
max_frame_size: std.atomic.Value(u32) = .init(16 * 1024),
