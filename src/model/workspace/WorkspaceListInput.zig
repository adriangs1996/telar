const EntryInput = @import("EntryInput.zig");
const WorkspaceListInput = @This();

revision: u64,
entries: []const EntryInput,
