const data = @import("model");
const Anchor = @import("Anchor.zig");
const limits = @import("limits.zig");

id: u64 = 0,
anchor: Anchor = .{ .revision = 0, .file = 0, .first = 0, .last = 0, .before = false },
body: data.GenericField(limits.comment_bytes) = .{},
alive: bool = false,
pending: bool = false,
draft: bool = true,
