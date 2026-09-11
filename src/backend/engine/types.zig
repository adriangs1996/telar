//! Values exchanged between the runtime and the engine actor. Prompts and
//! replies are bounded so a request never allocates on its way in or out.

const PromptType = @import("Prompt.zig");
const std = @import("std");

pub const max_prompt_bytes = 8 * 1024;
pub const max_reply_bytes = 4 * 1024;
pub const max_pending_requests = 8;

pub const Options = @import("Options.zig");

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

pub const Prompt = @import("Prompt.zig");

pub const Request = union(enum) {
    prompt: PromptType,
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

pub const Response = @import("Response.zig");

test "a prompt is bounded on both ends" {
    const purpose: Purpose = .{ .suggestion = .{ .client_id = 1, .client_generation = 1, .request_id = 1 } };
    try std.testing.expectError(error.InvalidPrompt, PromptType.init(purpose, ""));
    try std.testing.expectError(error.InvalidPrompt, PromptType.init(purpose, &([_]u8{'a'} ** (max_prompt_bytes + 1))));

    const prompt = try PromptType.init(purpose, "Create a title");
    try std.testing.expectEqualStrings("Create a title", prompt.slice());
    try std.testing.expectEqual(@as(u64, 1), prompt.purpose.suggestion.client_id);
}
