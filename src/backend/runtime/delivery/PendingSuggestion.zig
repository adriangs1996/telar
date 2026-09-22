const core = @import("telar-core");
/// One engine reply for a command suggestion, copied out of the engine
/// response so the queue owns it.
const PendingSuggestion = @This();

request_id: core.RequestId,
status: core.SuggestionStatus,
text: [core.max_suggestion_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(pending: *const PendingSuggestion) []const u8 {
    return pending.text[0..pending.text_len];
}
