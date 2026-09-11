const Entry = @import("Entry.zig");
const Inspection = @This();

entry: Entry,
output: []const u8,
output_hint: []const u8
