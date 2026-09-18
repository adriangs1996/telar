const std = @import("std");
text: []const u8,
images: *const @import("telar-core").AgentImages,
skills: *const @import("SkillCatalog.zig"),

/// Adds exact advertised skill paths without filesystem access or model lookup.
/// Example: `try writer.write(PromptInputs{ .text = prompt, .skills = catalog });`
pub fn jsonStringify(input: @This(), writer: *std.json.Stringify) !void {
    try writer.beginArray();
    if (input.text.len != 0) {
        try writer.write(.{ .type = "text", .text = input.text });
    }

    for (0..input.images.count) |index| {
        try writer.write(.{ .type = "localImage", .path = input.images.path(index) });
    }
    for (input.skills.value.entries[0..input.skills.value.count], 0..) |skill, index| {
        if (input.skills.value.mentioned(input.text, @intCast(index))) {
            try writer.write(.{ .type = "skill", .name = skill.name(&input.skills.value), .path = input.skills.path(@intCast(index)) });
        }
    }

    try writer.endArray();
}
