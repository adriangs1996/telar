const std = @import("std");

const Sink = @import("Sink.zig");
const SyncInput = @import("SyncInput.zig");
const window_title = @import("window_title.zig");

const State = @This();

sent: [window_title.max_title_bytes]u8 = undefined,
sent_len: u16 = 0,
ever_sent: bool = false,

pub fn sync(self: *State, sink: Sink, input: SyncInput) !bool {
    if (input.template.len == 0) {
        return false;
    }

    var buffer: [window_title.max_title_bytes]u8 = undefined;
    const title = window_title.render(&buffer, input.template, input.tokens);

    if (self.ever_sent and std.mem.eql(u8, self.sent[0..self.sent_len], title)) {
        return false;
    }

    try sink.set(sink.context, title);

    @memcpy(self.sent[0..title.len], title);
    self.sent_len = @intCast(title.len);
    self.ever_sent = true;

    return true;
}
