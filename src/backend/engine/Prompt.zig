const types = @import("types.zig");
const Prompt = @This();

purpose: types.Purpose,
bytes: [types.max_prompt_bytes]u8 = undefined,
len: u16 = 0,

/// Builds a bounded prompt.
///
/// ```zig
/// const prompt = try Prompt.init(.{ .suggestion = suggestion }, text);
/// ```
pub fn init(purpose: types.Purpose, text: []const u8) !Prompt {
    if (text.len == 0 or text.len > types.max_prompt_bytes) {
        return error.InvalidPrompt;
    }

    var prompt: Prompt = .{ .purpose = purpose, .len = @intCast(text.len) };
    @memcpy(prompt.bytes[0..text.len], text);
    return prompt;
}

pub fn slice(prompt: *const Prompt) []const u8 {
    return prompt.bytes[0..prompt.len];
}
