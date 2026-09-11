const CommandTools = @This();
const source_namespace = @import("agent_manifest.zig");
const CommandTool = @import("CommandTool.zig");
const std = @import("std");
items: [source_namespace.max_command_tools]CommandTool = undefined,
count: u8 = 0,

pub fn append(mappings: *CommandTools, tool: []const u8, field: []const u8) source_namespace.ListError!void {
    if (tool.len == 0 or field.len == 0) {
        return error.EmptyEntry;
    }
    if (tool.len > source_namespace.max_tool_name_bytes or field.len > source_namespace.max_command_field_bytes) {
        return error.EntryTooLong;
    }
    if (mappings.count == source_namespace.max_command_tools) {
        return error.TooManyEntries;
    }

    const mapping = &mappings.items[mappings.count];
    @memcpy(mapping.tool[0..tool.len], tool);
    mapping.tool_len = @intCast(tool.len);
    @memcpy(mapping.field[0..field.len], field);
    mapping.field_len = @intCast(field.len);
    mappings.count += 1;
}

pub fn commandField(mappings: *const CommandTools, tool: []const u8) ?[]const u8 {
    for (mappings.items[0..mappings.count]) |*mapping| {
        if (std.mem.eql(u8, mapping.toolSlice(), tool)) {
            return mapping.fieldSlice();
        }
    }

    return null;
}
