const core = @import("telar-core");
const AgentKey = @import("../agents/AgentKey.zig");
/// The last rows of the pane a peek shows, as the runtime last read them.
/// Disposable client state: it lives while the peek is open.
const PeekScreen = @This();

/// Bytes of pane text a peek keeps.
pub const max_text_bytes = 4096;
/// Rows a peek asks the runtime for.
pub const rows = 16;

agent: ?AgentKey = null,
text: [max_text_bytes]u8 = undefined,
text_len: usize = 0,
/// Whether a read is on its way, so snapshots do not queue duplicates.
reading: bool = false,
revision: u64 = 0,

/// Starts showing `agent`, dropping the text of any earlier one.
/// Example: `model.peek_screen.show(key);`.
pub fn show(self: *PeekScreen, agent: AgentKey) void {
    self.agent = agent;
    self.text_len = 0;
    self.reading = false;
    self.revision +%= 1;
}

/// Stores one read, keeping its last bytes. Returns whether it applied.
/// Example: `_ = model.peek_screen.store(key.pane_id, text);`.
pub fn store(self: *PeekScreen, pane_id: core.PaneId, text: []const u8) bool {
    self.reading = false;
    const agent = self.agent orelse return false;
    if (agent.pane_id != pane_id) {
        return false;
    }

    const kept = text[text.len -| max_text_bytes..];
    @memcpy(self.text[0..kept.len], kept);
    self.text_len = kept.len;
    self.revision +%= 1;
    return true;
}

/// Stops showing any pane. Example: `model.peek_screen.close();`.
pub fn close(self: *PeekScreen) void {
    self.agent = null;
    self.text_len = 0;
    self.reading = false;
    self.revision +%= 1;
}

pub fn slice(self: *const PeekScreen) []const u8 {
    return self.text[0..self.text_len];
}
