const review = @import("change_review.zig");
id: u64 = 0,
path: []const u8 = "",
first_line: u32 = 0,
last_line: u32 = 0,
side: review.Side = .after,
body: []const u8 = "",
draft: bool = false,
