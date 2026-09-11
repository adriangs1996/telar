const FrameResource = @This();
const source_namespace = @import("root.zig");
encoded_name: []const u8,
byte_len: usize,
limit: usize,
medium: source_namespace.Medium,
