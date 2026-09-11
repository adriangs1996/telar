const HostInput = @This();
const source_namespace = @import("terminal_browser_pane.zig");
const std = @import("std");
pending: [4096]u8 = undefined,
len: usize = 0,

const Result = struct {
    stop: bool = false,
    capabilities_changed: bool = false,
};

const FeedContext = struct {
    io: source_namespace.Io,
    session: *source_namespace.pty.Session,
    capabilities: *source_namespace.HostCapabilities,
};

fn feed(input: *HostInput, context: FeedContext, bytes: []const u8) !Result {
    if (bytes.len > input.pending.len - input.len) {
        return error.HostInputOverflow;
    }
    @memcpy(input.pending[input.len..][0..bytes.len], bytes);
    input.len += bytes.len;

    var result: Result = .{};
    while (input.len != 0) {
        const parsed = source_namespace.term.parse(input.pending[0..input.len]) orelse break;
        if (parsed.len == 0) {
            break;
        }
        const raw = input.pending[0..parsed.len];
        switch (parsed.event) {
            .terminal_response => |response| {
                result.capabilities_changed = source_namespace.observeHostCapability(context.capabilities, response) or
                    result.capabilities_changed;
            },
            // Unknown host responses are not child input.
            .incomplete => {},
            else => {
                // Ctrl+] is the reproducer's only local binding.
                if (raw.len == 1 and raw[0] == 0x1d) {
                    result.stop = true;
                } else {
                    try context.session.writeAll(context.io, raw);
                }
            },
        }
        input.discard(parsed.len);
        if (result.stop) {
            break;
        }
    }
    return result;
}

fn discard(input: *HostInput, count: usize) void {
    std.mem.copyForwards(
        u8,
        input.pending[0 .. input.len - count],
        input.pending[count..input.len],
    );
    input.len -= count;
}
