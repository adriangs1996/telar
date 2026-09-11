const State = @This();
const source_namespace = @import("window_title.zig");
const Sink = @import("Sink.zig");
const SyncInput = @import("SyncInput.zig");
const std = @import("std");
sent: [source_namespace.max_title_bytes]u8 = undefined,
sent_len: u16 = 0,
ever_sent: bool = false,

/// Sends changed text through the host port. Failure preserves the cache.
/// Example: `try state.sync(sink, .{ .template = "{tab}", .tokens = tokens });`.
pub fn sync(state: *State, sink: Sink, input: SyncInput) !void {
    if (input.template.len == 0) {
        return;
    }

    var buffer: [source_namespace.max_title_bytes]u8 = undefined;
    const title = source_namespace.render(&buffer, input.template, input.tokens);
    if (state.ever_sent and std.mem.eql(u8, state.sent[0..state.sent_len], title)) {
        return;
    }

    try sink.set(sink.context, title);
    @memcpy(state.sent[0..title.len], title);
    state.sent_len = @intCast(title.len);
    state.ever_sent = true;
}
