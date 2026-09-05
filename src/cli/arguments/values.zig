//! Shared typed CLI values; no command dispatch or side effects.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor.zig").Cursor;

pub const Target = union(enum) {
    /// The pane this process runs in, from `TELAR_PANE_ID`.
    current,
    pane: u64,
    name: [*:0]const u8,

    pub fn parse(value: [*:0]const u8) Target {
        const text = std.mem.span(value);
        if (std.mem.eql(u8, text, "--current")) {
            return .current;
        }

        if (std.fmt.parseUnsigned(u64, text, 10)) |raw| {
            return .{ .pane = raw };
        } else |_| {
            return .{ .name = value };
        }
    }
};

pub const max_wait_timeout_seconds = 3600;

pub const default_wait_timeout_seconds = 30;

pub const HookAgent = enum { claude, codex, pi };

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

    return error.UnknownHookAgent;
}

pub fn parseWaitStatus(text: []const u8) !core.schema.AgentStatus {
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
    if (lines == 0 or lines > core.schema.max_pane_text_rows) {
        return error.InvalidLineCount;
    }

    return lines;
}

pub fn parseTextSource(text: []const u8) !core.schema.PaneTextSource {
    if (std.mem.eql(u8, text, "screen")) {
        return .screen;
    }
    if (std.mem.eql(u8, text, "recent")) {
        return .recent;
    }
    return error.InvalidTextSource;
}
