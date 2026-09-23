const std = @import("std");
const term = @import("../../presentation/screen_support.zig");
const StartupInput = @This();

pub const capacity = 8192;
held: [capacity]u8 = undefined,
held_len: usize = 0,
pending: [4096]u8 = undefined,
pending_len: usize = 0,
paste: bool = false,

/// Retain early user input and yield host replies one at a time.
/// Example: `while (try state.next(&bytes)) |reply| try observe(reply);`
pub fn next(self: *StartupInput, incoming: *[]const u8) !?term.Event.TerminalResponse {
    while (true) {
        const count = @min(incoming.len, self.pending.len - self.pending_len);
        @memcpy(self.pending[self.pending_len..][0..count], incoming.*[0..count]);
        self.pending_len += count;
        incoming.* = incoming.*[count..];
        var offset: usize = 0;
        defer self.consume(offset);
        while (offset < self.pending_len) {
            const bytes = self.pending[offset..self.pending_len];
            if (self.paste) {
                const end = "\x1b[201~";
                if (std.mem.startsWith(u8, bytes, end)) {
                    self.paste = false;
                    try self.retain(bytes[0..end.len]);
                    offset += end.len;
                } else if (std.mem.startsWith(u8, end, bytes)) {
                    break;
                } else {
                    try self.retain(bytes[0..1]);
                    offset += 1;
                }
                continue;
            }
            if (bytes.len == 1 and bytes[0] == 0x1b) {
                break;
            }
            const parsed = term.parse(bytes) orelse break;
            if (parsed.len == 0) {
                break;
            }
            offset += parsed.len;
            switch (parsed.event) {
                .terminal_response => |response| return response,
                .incomplete => {},
                else => {
                    if (parsed.event == .paste_start) {
                        self.paste = true;
                    }
                    try self.retain(bytes[0..parsed.len]);
                },
            }
        }
        if (incoming.len == 0) {
            return null;
        }
        if (offset == 0 and self.pending_len == self.pending.len) {
            return error.StartupInputOverflow;
        }
    }
}

fn retain(state: *StartupInput, bytes: []const u8) !void {
    if (bytes.len > state.held.len - state.held_len) {
        return error.StartupInputOverflow;
    }

    @memcpy(state.held[state.held_len..][0..bytes.len], bytes);
    state.held_len += bytes.len;
}

fn consume(state: *StartupInput, len: usize) void {
    std.mem.copyForwards(u8, &state.pending, state.pending[len..state.pending_len]);
    state.pending_len -= len;
}

/// Moves an unfinished escape prefix into the replay, where the normal
/// input router resumes parsing it across subsequent reads.
/// Example: `const bytes = try state.finish();`.
pub fn finish(state: *StartupInput) ![]const u8 {
    try state.retain(state.pending[0..state.pending_len]);
    state.pending_len = 0;
    const len = state.held_len;
    state.held_len = 0;
    return state.held[0..len];
}
