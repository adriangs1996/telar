const EntryInput = @import("EntryInput.zig");
const SnapshotInput = @This();

revision: u64,
entries: []const EntryInput,
