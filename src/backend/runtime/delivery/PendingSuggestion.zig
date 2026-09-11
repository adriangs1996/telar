/// One engine reply for a command suggestion, copied out of the engine
/// response so the queue owns it.
const PendingSuggestion = @This();
const source_namespace = @import("response_queue.zig");
request_id: source_namespace.schema.RequestId,
status: source_namespace.schema.SuggestionStatus,
text: [source_namespace.schema.max_suggestion_bytes]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(pending: *const PendingSuggestion) []const u8 {
    return pending.text[0..pending.text_len];
}
