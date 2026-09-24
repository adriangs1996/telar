//! One `key=value` field of a graphics command's control data.
const ControlField = @This();

key: u8,
value: []const u8,
