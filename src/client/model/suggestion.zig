//! Bounded state for the command-suggestion palette: at most one request
//! in flight and one suggested line. Only the awaited reply lands; editing
//! the request text discards a suggestion so Enter asks again.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const max_text_bytes = schema.max_suggestion_bytes;

pub const Phase = enum {
    /// Nothing asked yet, or the request text changed since the last reply.
    idle,
    waiting,
    ready,
    failed,
};

pub const State = @import("SuggestionState.zig");

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
