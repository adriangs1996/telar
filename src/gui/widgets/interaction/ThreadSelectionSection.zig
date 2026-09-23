const ThreadTextRow = @import("ThreadTextRow.zig");
const MessageLayoutOwner = @import("../MessageLayoutOwner.zig");

row: ThreadTextRow,
owner: MessageLayoutOwner,
text: []const u8,
markdown: bool = false,
code: bool = false,
