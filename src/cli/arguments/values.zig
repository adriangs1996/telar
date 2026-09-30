//! Shared typed CLI values; no command dispatch or side effects.

const core = @import("telar-core");
const std = @import("std");

pub const Target = union(enum) {
    /// The pane this process runs in, from `TELAR_PANE_ID`.
    current,
    pane: u64,
    name: [*:0]const u8,
    /// The agent in a tracked worktree, named by branch or title after
    /// `worktree:`.
    worktree: [*:0]const u8,

    pub fn parse(value: [*:0]const u8) Target {
        const text = std.mem.span(value);
        if (std.mem.eql(u8, text, "--current")) {
            return .current;
        }

        if (std.mem.startsWith(u8, text, worktree_prefix) and text.len > worktree_prefix.len) {
            return .{ .worktree = value + worktree_prefix.len };
        }

        if (std.fmt.parseUnsigned(u64, text, 10)) |raw| {
            return .{ .pane = raw };
        } else |_| {
            return .{ .name = value };
        }
    }
};

pub const worktree_prefix = "worktree:";

/// A day: an agent turn that runs a long build or test suite outlasts an
/// hour, and a coordinator should not have to loop around the wait.
pub const max_wait_timeout_seconds = 24 * 60 * 60;

pub const default_wait_timeout_seconds = 30;

pub const HookAgent = enum { claude, codex, pi, cursor, opencode };

pub fn parseHookAgent(text: []const u8) !HookAgent {
    if (std.mem.eql(u8, text, "claude")) {
        return .claude;
    }
    if (std.mem.eql(u8, text, "codex")) {
        return .codex;
    }
    if (std.mem.eql(u8, text, "pi")) {
        return .pi;
    }
    if (std.mem.eql(u8, text, "cursor")) {
        return .cursor;
    }
    if (std.mem.eql(u8, text, "opencode")) {
        return .opencode;
    }

    return error.UnknownHookAgent;
}

/// What `agent wait --until` waits for: one status, or `finished`, which is
/// `done` or `ready`, whether or not a person saw the turn end.
pub const WaitCondition = union(enum) {
    status: core.AgentStatus,
    finished,

    pub fn matches(self: WaitCondition, status: core.AgentStatus) bool {
        return switch (self) {
            .status => |wanted| status == wanted,
            .finished => status == .done or status == .ready,
        };
    }
};

pub fn parseWaitCondition(text: []const u8) !WaitCondition {
    if (std.mem.eql(u8, text, "finished")) {
        return .finished;
    }

    return .{ .status = try parseWaitStatus(text) };
}

pub fn parseWaitStatus(text: []const u8) !core.AgentStatus {
    if (std.mem.eql(u8, text, "done")) {
        return .done;
    }
    if (std.mem.eql(u8, text, "ready") or std.mem.eql(u8, text, "idle")) {
        return .ready;
    }
    if (std.mem.eql(u8, text, "blocked")) {
        return .blocked;
    }
    if (std.mem.eql(u8, text, "working")) {
        return .working;
    }
    if (std.mem.eql(u8, text, "failed")) {
        return .failed;
    }
    return error.InvalidWaitStatus;
}

pub fn parseTimeoutSeconds(text: []const u8) !u32 {
    const seconds = std.fmt.parseUnsigned(u32, std.mem.trimEnd(u8, text, "s"), 10) catch
        return error.InvalidTimeout;
    if (seconds == 0 or seconds > max_wait_timeout_seconds) {
        return error.InvalidTimeout;
    }

    return seconds;
}

pub fn parseLineCount(text: []const u8) !u16 {
    const lines = std.fmt.parseUnsigned(u16, text, 10) catch return error.InvalidLineCount;
    if (lines == 0 or lines > core.max_pane_text_rows) {
        return error.InvalidLineCount;
    }

    return lines;
}

pub fn parseTextSource(text: []const u8) !core.PaneTextSource {
    if (std.mem.eql(u8, text, "screen")) {
        return .screen;
    }
    if (std.mem.eql(u8, text, "recent")) {
        return .recent;
    }
    return error.InvalidTextSource;
}

test "waits run up to a day and reads up to every row a reply carries" {
    try std.testing.expectEqual(@as(u32, 24 * 60 * 60), try parseTimeoutSeconds("86400s"));
    try std.testing.expectError(error.InvalidTimeout, parseTimeoutSeconds("86401"));
    try std.testing.expectError(error.InvalidTimeout, parseTimeoutSeconds("0"));

    try std.testing.expectEqual(@as(u16, core.max_pane_text_rows), try parseLineCount("2000"));
    try std.testing.expectError(error.InvalidLineCount, parseLineCount("2001"));
}
