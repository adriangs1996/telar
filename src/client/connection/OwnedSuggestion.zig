const OwnedSuggestion = @This();
const source_namespace = @import("outbox_support.zig");
/// The request comes from the prompt field, bounded by the tab-label
/// capacity; the cap keeps queue messages small.
pub const max_text_bytes = 128;

request_id: source_namespace.schema.RequestId,
pane_id: source_namespace.schema.PaneId,
text: [max_text_bytes]u8 = undefined,
text_len: u8 = 0,

pub fn view(value: *const OwnedSuggestion) source_namespace.schema.SuggestCommand {
    return .{
        .request_id = value.request_id,
        .pane_id = value.pane_id,
        .text = value.text[0..value.text_len],
    };
}
