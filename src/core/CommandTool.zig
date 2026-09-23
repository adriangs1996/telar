const agent_manifest = @import("agent_manifest.zig");
const CommandTool = @This();

tool: [agent_manifest.max_tool_name_bytes]u8 = undefined,
tool_len: u8,
field: [agent_manifest.max_command_field_bytes]u8 = undefined,
field_len: u8,

pub fn toolSlice(self: *const CommandTool) []const u8 {
    return self.tool[0..self.tool_len];
}

pub fn fieldSlice(self: *const CommandTool) []const u8 {
    return self.field[0..self.field_len];
}
