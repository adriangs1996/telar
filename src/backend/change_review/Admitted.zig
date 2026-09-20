const std = @import("std");
const Context = @import("Context.zig");
const Group = @import("Group.zig");
context: Context,
editions: std.StaticBitSet(Group.archive_capacity) = .initEmpty(),
