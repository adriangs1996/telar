const agent_manifest = @import("agent_manifest.zig");
const CommandTool = @import("CommandTool.zig");
const std = @import("std");
const CommandTools = @This();

items: [agent_manifest.max_command_tools]CommandTool = undefined,
count: u8 = 0,

pub fn append(self: *CommandTools, tool: []const u8, field: []const u8) agent_manifest.ListError!void {
    if (tool.len == 0 or field.len == 0) {
        return error.EmptyEntry;
    }
    if (tool.len > agent_manifest.max_tool_name_bytes or field.len > agent_manifest.max_command_field_bytes) {
        return error.EntryTooLong;
    }
    if (self.count == agent_manifest.max_command_tools) {
        return error.TooManyEntries;
    }

    const mapping = &self.items[self.count];
    @memcpy(mapping.tool[0..tool.len], tool);
    mapping.tool_len = @intCast(tool.len);
    @memcpy(mapping.field[0..field.len], field);
    mapping.field_len = @intCast(field.len);
    self.count += 1;
}

pub fn commandField(self: *const CommandTools, tool: []const u8) ?[]const u8 {
    for (self.items[0..self.count]) |*mapping| {
        if (std.mem.eql(u8, mapping.toolSlice(), tool)) {
            return mapping.fieldSlice();
        }
    }

    return null;
}
