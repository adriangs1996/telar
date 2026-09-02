//! Values exchanged between the runtime and the engine actor. Prompts and
//! replies are bounded so a request never allocates on its way in or out.

const std = @import("std");

pub const max_prompt_bytes = 8 * 1024;
pub const max_reply_bytes = 4 * 1024;
pub const max_pending_requests = 8;

pub const Options = struct {
    arguments: []const []const u8,
    /// Deadline for one prompt, from the command write to the assistant text.
    timeout_ms: u32,
    /// Idle interval after which the child is killed. The runtime asks for
    /// the check on its own cadence; the engine never runs a timer.
    idle_timeout_ms: u32,
};

/// Identifies who asked, so the runtime routes a reply without keeping
/// per-request state.
pub const Purpose = union(enum) {
    suggestion: Suggestion,

    /// A client's command-suggestion request, answered to that exact
    /// client session.
    pub const Suggestion = struct {
        client_id: u64,
        client_generation: u64,
        request_id: u64,
    };
};

pub const Prompt = struct {
    purpose: Purpose,
    bytes: [max_prompt_bytes]u8 = undefined,
    len: u16 = 0,

    /// Builds a bounded prompt.
    ///
    /// ```zig
    /// const prompt = try Prompt.init(.{ .suggestion = suggestion }, text);
    /// ```
    pub fn init(purpose: Purpose, text: []const u8) !Prompt {
        if (text.len == 0 or text.len > max_prompt_bytes) {
            return error.InvalidPrompt;
        }

        var prompt: Prompt = .{ .purpose = purpose, .len = @intCast(text.len) };
        @memcpy(prompt.bytes[0..text.len], text);
        return prompt;
    }

    pub fn slice(prompt: *const Prompt) []const u8 {
        return prompt.bytes[0..prompt.len];
    }
};

pub const Request = union(enum) {
    prompt: Prompt,
    idle_check,
};

pub const Status = enum {
    success,
    /// The command could not start at all.
    unavailable,
    timeout,
    /// The engine answered, but not with usable text.
    invalid_output,
    failed,
};

pub const Response = struct {
    purpose: Purpose,
    status: Status,
    text: [max_reply_bytes]u8 = undefined,
    text_len: u16 = 0,

    pub fn textSlice(response: *const Response) []const u8 {
        return response.text[0..response.text_len];
    }
};

test "a prompt is bounded on both ends" {
    const purpose: Purpose = .{ .suggestion = .{ .client_id = 1, .client_generation = 1, .request_id = 1 } };
    try std.testing.expectError(error.InvalidPrompt, Prompt.init(purpose, ""));
    try std.testing.expectError(error.InvalidPrompt, Prompt.init(purpose, &([_]u8{'a'} ** (max_prompt_bytes + 1))));

    const prompt = try Prompt.init(purpose, "Create a title");
    try std.testing.expectEqualStrings("Create a title", prompt.slice());
    try std.testing.expectEqual(@as(u64, 1), prompt.purpose.suggestion.client_id);
}
