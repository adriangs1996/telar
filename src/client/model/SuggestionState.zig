const State = @This();
const source_namespace = @import("suggestion.zig");
revision: u64 = 0,
pending_request: u64 = 0,
phase: source_namespace.Phase = .idle,
status: source_namespace.schema.SuggestionStatus = .ready,
text: [source_namespace.max_text_bytes]u8 = undefined,
text_len: u16 = 0,

/// Clears everything when the palette opens.
///
/// ```zig
/// model.suggestion.begin();
/// ```
pub fn begin(state: *State) void {
    state.pending_request = 0;
    state.phase = .idle;
    state.text_len = 0;
    state.revision +%= 1;
}

/// Records the request whose reply is awaited and shows the waiting
/// state. Older replies become stale immediately.
///
/// ```zig
/// model.suggestion.expect(schema.id.raw(request_id));
/// ```
pub fn expect(state: *State, request_id: u64) void {
    state.pending_request = request_id;
    state.phase = .waiting;
    state.text_len = 0;
    state.revision +%= 1;
}

/// Discards a landed or pending suggestion because the request text
/// changed. A reply for the discarded request is then ignored.
///
/// ```zig
/// model.suggestion.invalidate();
/// ```
pub fn invalidate(state: *State) void {
    if (state.phase == .idle) {
        return;
    }

    state.pending_request = 0;
    state.phase = .idle;
    state.text_len = 0;
    state.revision +%= 1;
}

/// Lands one reply. Replies for any other request are ignored.
///
/// ```zig
/// _ = model.suggestion.apply(.{ .request_id = request_id, .status = .ready, .text = "ls" });
/// ```
pub fn apply(state: *State, suggestion: source_namespace.schema.CommandSuggestion) bool {
    const request_id = source_namespace.schema.id.raw(suggestion.request_id);
    if (request_id == 0 or request_id != state.pending_request) {
        return false;
    }

    state.pending_request = 0;
    state.status = suggestion.status;
    const len = @min(suggestion.text.len, source_namespace.max_text_bytes);
    @memcpy(state.text[0..len], suggestion.text[0..len]);
    state.text_len = @intCast(len);
    state.phase = if (suggestion.status == .ready and len != 0) .ready else .failed;
    state.revision +%= 1;
    return true;
}

pub fn textSlice(state: *const State) []const u8 {
    return state.text[0..state.text_len];
}

pub fn version(state: *const State) u64 {
    return state.revision;
}
