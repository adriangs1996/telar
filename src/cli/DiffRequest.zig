const DiffScope = @import("DiffScope.zig").DiffScope;
/// What `diff` compares.
const DiffRequest = @This();

directory: []const u8,
base: []const u8,
scope: DiffScope,
stat: bool,
