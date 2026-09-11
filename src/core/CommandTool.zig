const agent_manifest = @import("agent_manifest.zig");
const CommandTool = @This();

tool: [agent_manifest.max_tool_name_bytes]u8 = undefined,
tool_len: u8,
field: [agent_manifest.max_command_field_bytes]u8 = undefined,
field_len: u8,

pub fn toolSlice(mapping: *const CommandTool) []const u8 {
    return mapping.tool[0..mapping.tool_len];
}

pub fn fieldSlice(mapping: *const CommandTool) []const u8 {
    return mapping.field[0..mapping.field_len];
}
