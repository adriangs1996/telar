const core = @import("telar-core");
const suggestion_ops = @import("suggestion.zig");
const State = @This();

revision: u64 = 0,
pending_request: u64 = 0,
phase: suggestion_ops.Phase = .idle,
status: core.SuggestionStatus = .ready,
text: [core.max_suggestion_bytes]u8 = undefined,
text_len: u16 = 0,

/// Clears everything when the palette opens.
///
/// ```zig
/// model.suggestion.begin();
/// ```
pub fn begin(self: *State) void {
    self.pending_request = 0;
    self.phase = .idle;
    self.text_len = 0;
    self.revision +%= 1;
}

/// Records the request whose reply is awaited and shows the waiting
/// state. Older replies become stale immediately.
///
/// ```zig
/// model.suggestion.expect(schema.id.raw(request_id));
/// ```
pub fn expect(self: *State, request_id: u64) void {
    self.pending_request = request_id;
    self.phase = .waiting;
    self.text_len = 0;
    self.revision +%= 1;
}

/// Discards a landed or pending suggestion because the request text
/// changed. A reply for the discarded request is then ignored.
///
/// ```zig
/// model.suggestion.invalidate();
/// ```
pub fn invalidate(self: *State) void {
    if (self.phase == .idle) {
        return;
    }

    self.pending_request = 0;
    self.phase = .idle;
    self.text_len = 0;
    self.revision +%= 1;
}

/// Lands one reply. Replies for any other request are ignored.
///
/// ```zig
/// _ = model.suggestion.apply(.{ .request_id = request_id, .status = .ready, .text = "ls" });
/// ```
pub fn apply(self: *State, suggestion: core.CommandSuggestion) bool {
    const request_id = core.raw(suggestion.request_id);
    if (request_id == 0 or request_id != self.pending_request) {
        return false;
    }

    self.pending_request = 0;
    self.status = suggestion.status;
    const len = @min(suggestion.text.len, core.max_suggestion_bytes);
    @memcpy(self.text[0..len], suggestion.text[0..len]);
    self.text_len = @intCast(len);
    self.phase = if (suggestion.status == .ready and len != 0) .ready else .failed;
    self.revision +%= 1;
    return true;
}

pub fn textSlice(self: *const State) []const u8 {
    return self.text[0..self.text_len];
}

pub fn version(self: *const State) u64 {
    return self.revision;
}
