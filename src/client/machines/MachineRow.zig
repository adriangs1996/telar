//! What one row of `Machines` is made from: the profile's id, label,
//! destination and color, and whether the window connects to it.
const core = @import("telar-core");
const MachineRow = @This();

id: core.MachineId = .invalid,
label: []const u8,
destination: []const u8 = "",
color: ?[]const u8 = null,
enabled: bool = true,
