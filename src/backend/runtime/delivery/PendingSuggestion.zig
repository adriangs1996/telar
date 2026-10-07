const core = @import("telar-core");
/// One engine reply for a command suggestion, copied out of the engine
/// response so the queue owns it.
const PendingSuggestion = @This();

request_id: core.RequestId,
status: core.SuggestionStatus,
// SAFETY: suggest_command copies a successful reply before enqueueing it; textSlice uses only text_len bytes.
text: [core.max_suggestion_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(self: *const PendingSuggestion) []const u8 {
    return self.text[0..self.text_len];
}
