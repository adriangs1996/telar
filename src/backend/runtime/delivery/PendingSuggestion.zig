const RequestIdType = @import("telar-core").RequestId;
const SuggestionStatusType = @import("telar-core").SuggestionStatus;
const max_suggestion_bytes_module = @import("telar-core").max_suggestion_bytes;
/// One engine reply for a command suggestion, copied out of the engine
/// response so the queue owns it.
const PendingSuggestion = @This();

request_id: RequestIdType,
status: SuggestionStatusType,
text: [max_suggestion_bytes_module]u8 = undefined,
text_len: u16 = 0,

pub fn textSlice(pending: *const PendingSuggestion) []const u8 {
    return pending.text[0..pending.text_len];
}
