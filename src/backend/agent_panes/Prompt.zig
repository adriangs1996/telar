const core = @import("telar-core");

bytes: [core.agent_thread.max_prompt_bytes]u8 = undefined,
len: u16 = 0,
images: core.AgentImages = .{},
options: core.AgentOptions = .{},

/// Keeps image-only and mixed submissions visible before the provider echoes them.
/// Example: `transcript.update(.{ .role = .user, .text = prompt.preview(&scratch) });`
pub fn preview(prompt: *const @This(), buffer: *[core.agent_thread.max_prompt_bytes + 64]u8) []const u8 {
    const std = @import("std");
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll(prompt.bytes[0..prompt.len]) catch unreachable;
    for (0..prompt.images.count) |index| {
        writer.print("{s}[Image {d}]", .{ if (writer.end != 0) "\n" else "", index + 1 }) catch unreachable;
    }

    return writer.buffered();
}
