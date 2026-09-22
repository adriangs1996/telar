const core = @import("telar-core");
const RenameTab = @This();

location: core.TabLocation,
/// Borrowed only for the synchronous `execute` call.
label: []const u8,
