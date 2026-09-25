const core = @import("telar-core");
const model = @import("model.zig");
const std = @import("std");
/// The title history persists for one agent session, with the state of its
/// generation; a pending or failed placeholder is stored too. The durable
/// title a checkpoint carries is `agent/SessionTitle`.
const StoredSessionTitle = @This();

pub const Definition = @import("Definition.zig");

id: model.SessionId,
title: [core.max_agent_session_title_bytes]u8 = undefined,
title_len: u8 = 0,
source: core.AgentTitleSource,
state: core.AgentTitleState,

/// Validates and owns the fixed-size representation persisted by history.
///
/// ```zig
/// const title = try StoredSessionTitle.init(.{ .id = id, .title = "Fix tests", .source = .generated, .state = .ready });
/// ```
pub fn init(definition: Definition) !StoredSessionTitle {
    const id = definition.id;
    const title_value = definition.title;
    const source = definition.source;
    const state = definition.state;

    if (title_value.len > core.max_agent_session_title_bytes) {
        return error.AgentTitleTooLong;
    }
    if (!std.unicode.utf8ValidateSlice(title_value)) {
        return error.InvalidAgentTitle;
    }
    for (title_value) |byte| if (byte < 0x20 or byte == 0x7f)
        return error.InvalidAgentTitle;
    switch (source) {
        .telar => if (state == .ready) return error.InvalidAgentTitle,
        .generated, .manual, .agent => if (state != .ready or title_value.len == 0)
            return error.InvalidAgentTitle,
        // A child's own window title is never persisted as a session title.
        .terminal => return error.InvalidAgentTitle,
    }
    var value: StoredSessionTitle = .{
        .id = id,
        .title_len = @intCast(title_value.len),
        .source = source,
        .state = state,
    };
    @memcpy(value.title[0..title_value.len], title_value);
    return value;
}

pub fn titleSlice(self: *const StoredSessionTitle) []const u8 {
    return self.title[0..self.title_len];
}
