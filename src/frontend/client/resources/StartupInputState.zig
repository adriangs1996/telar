const std = @import("std");
const term = @import("../../presentation/screen_support.zig");
const State = @This();

pub const capacity = 8192;
held: [capacity]u8 = undefined,
held_len: usize = 0,
pending: [4096]u8 = undefined,
pending_len: usize = 0,
paste: bool = false,

/// Example: `try state.feed(bytes, &terminal_response_handler);`.
pub fn feed(state: *State, bytes: []const u8, handler: anytype) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = @min(bytes.len - offset, state.pending.len - state.pending_len);
        if (count == 0) {
            return error.StartupInputOverflow;
        }

        @memcpy(state.pending[state.pending_len..][0..count], bytes[offset..][0..count]);
        state.pending_len += count;
        offset += count;
        try state.drain(handler);
    }
}

fn drain(state: *State, handler: anytype) !void {
    var offset: usize = 0;
    defer state.consume(offset);
    while (offset < state.pending_len) {
        const bytes = state.pending[offset..state.pending_len];
        if (state.paste) {
            const end = "\x1b[201~";
            if (std.mem.startsWith(u8, bytes, end)) {
                state.paste = false;
                try state.retain(bytes[0..end.len]);
                offset += end.len;
            } else if (std.mem.startsWith(u8, end, bytes)) {
                return;
            } else {
                try state.retain(bytes[0..1]);
                offset += 1;
            }

            continue;
        }

        if (bytes.len == 1 and bytes[0] == 0x1b) {
            return;
        }

        const parsed = term.parse(bytes) orelse return;
        if (parsed.len == 0) {
            return;
        }

        switch (parsed.event) {
            .terminal_response => |response| {
                try handler.terminalResponse(response);
            },
            .incomplete => {},
            else => {
                if (parsed.event == .paste_start) {
                    state.paste = true;
                }

                try state.retain(bytes[0..parsed.len]);
            },
        }

        offset += parsed.len;
    }
}

fn retain(state: *State, bytes: []const u8) !void {
    if (bytes.len > state.held.len - state.held_len) {
        return error.StartupInputOverflow;
    }

    @memcpy(state.held[state.held_len..][0..bytes.len], bytes);
    state.held_len += bytes.len;
}

fn consume(state: *State, len: usize) void {
    std.mem.copyForwards(u8, &state.pending, state.pending[len..state.pending_len]);
    state.pending_len -= len;
}

/// Moves an unfinished escape prefix into the replay, where the normal
/// input router resumes parsing it across subsequent reads.
/// Example: `const bytes = try state.finish();`.
pub fn finish(state: *State) ![]const u8 {
    try state.retain(state.pending[0..state.pending_len]);
    state.pending_len = 0;
    const len = state.held_len;
    state.held_len = 0;
    return state.held[0..len];
}
