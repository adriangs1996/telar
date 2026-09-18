const std = @import("std");

kind: Kind,
argument: []const u8 = "",

pub const Kind = enum { clear, rename, model, permissions, skills };
pub const kinds = std.enums.values(Kind);

/// Example: `const command = AgentCommand.parse(draft) orelse return;`
pub fn parse(text: []const u8) ?@This() {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (input.len == 0 or input[0] != '/') {
        return null;
    }

    const end = std.mem.indexOfAny(u8, input, " \t\r\n") orelse input.len;
    const kind = std.meta.stringToEnum(Kind, input[1..end]) orelse return null;
    return .{ .kind = kind, .argument = std.mem.trim(u8, input[end..], " \t\r\n") };
}

/// Example: `draw(AgentCommand.description(.clear));`
pub fn description(kind: Kind) []const u8 {
    return switch (kind) {
        .clear => "Start a new conversation in this pane",
        .rename => "Rename this conversation",
        .model => "Choose the model for the next message",
        .permissions => "Choose agent permissions",
        .skills => "Browse available skills",
    };
}
