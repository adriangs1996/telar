/// What `add` checks out.
const WorktreeCheckout = @This();

root: []const u8,
directory: []const u8,
branch: []const u8,
/// Where a new branch starts; ignored when the branch exists.
base: []const u8,
