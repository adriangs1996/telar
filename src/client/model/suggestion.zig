//! Bounded state for the command-suggestion palette: at most one request
//! in flight and one suggested line. Only the awaited reply lands; editing
//! the request text discards a suggestion so Enter asks again.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_text_bytes = schema.max_suggestion_bytes;

pub const Phase = enum {
    /// Nothing asked yet, or the request text changed since the last reply.
    idle,
    waiting,
    ready,
    failed,
};

pub const State = struct {
    revision: u64 = 0,
    pending_request: u64 = 0,
    phase: Phase = .idle,
    status: schema.SuggestionStatus = .ready,
    text: [max_text_bytes]u8 = undefined,
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
    pub fn apply(state: *State, suggestion: schema.CommandSuggestion) bool {
        const request_id = schema.id.raw(suggestion.request_id);
        if (request_id == 0 or request_id != state.pending_request) {
            return false;
        }

        state.pending_request = 0;
        state.status = suggestion.status;
        const len = @min(suggestion.text.len, max_text_bytes);
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
};

test "only the awaited reply lands and edits discard it" {
    var state: State = .{};
    state.begin();
    state.expect(7);
    try std.testing.expectEqual(Phase.waiting, state.phase);

    try std.testing.expect(!state.apply(.{ .request_id = @enumFromInt(6), .status = .ready, .text = "ls" }));
    try std.testing.expectEqual(Phase.waiting, state.phase);

    try std.testing.expect(state.apply(.{ .request_id = @enumFromInt(7), .status = .ready, .text = "ls -la" }));
    try std.testing.expectEqual(Phase.ready, state.phase);
    try std.testing.expectEqualStrings("ls -la", state.textSlice());
    try std.testing.expect(!state.apply(.{ .request_id = @enumFromInt(7), .status = .ready, .text = "again" }));

    const before = state.version();
    state.invalidate();
    try std.testing.expectEqual(Phase.idle, state.phase);
    try std.testing.expectEqual(@as(u16, 0), state.text_len);
    try std.testing.expect(state.version() != before);
    state.invalidate();
    try std.testing.expectEqual(before + 1, state.version());

    state.expect(8);
    try std.testing.expect(state.apply(.{ .request_id = @enumFromInt(8), .status = .timeout }));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqual(schema.SuggestionStatus.timeout, state.status);

    state.expect(9);
    try std.testing.expect(state.apply(.{ .request_id = @enumFromInt(9), .status = .ready }));
    try std.testing.expectEqual(Phase.failed, state.phase);
}
