const RequestIdType = @import("telar-core").RequestId;
const PaneIdType = @import("telar-core").PaneId;
const SuggestCommandType = @import("telar-core").SuggestCommand;
const OwnedSuggestion = @This();

/// The request comes from the prompt field, bounded by the tab-label
/// capacity; the cap keeps queue messages small.
pub const max_text_bytes = 128;

request_id: RequestIdType,
pane_id: PaneIdType,
text: [max_text_bytes]u8 = undefined,
text_len: u8 = 0,

pub fn view(value: *const OwnedSuggestion) SuggestCommandType {
    return .{
        .request_id = value.request_id,
        .pane_id = value.pane_id,
        .text = value.text[0..value.text_len],
    };
}
