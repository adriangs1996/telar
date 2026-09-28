//! What a new machine profile is made from, before validation.
const MachineProfileFields = @This();

label: []const u8,
destination: []const u8,
color: ?[]const u8 = null,
enabled: bool = true,
