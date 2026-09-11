const DefinitionType = @import("Definition.zig");
const model = @import("model.zig");
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const std = @import("std");
const SessionTitle = @This();

pub const Definition = @import("Definition.zig");

id: model.SessionId,
title: [max_agent_session_title_bytes_module]u8 = undefined,
title_len: u8 = 0,
source: AgentTitleSourceType,
state: AgentTitleStateType,

/// Validates and owns the fixed-size representation persisted by history.
///
/// ```zig
/// const title = try SessionTitle.init(.{ .id = id, .title = "Fix tests", .source = .generated, .state = .ready });
/// ```
pub fn init(definition: DefinitionType) !SessionTitle {
    const id = definition.id;
    const title_value = definition.title;
    const source = definition.source;
    const state = definition.state;

    if (title_value.len > max_agent_session_title_bytes_module) {
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
    var value: SessionTitle = .{
        .id = id,
        .title_len = @intCast(title_value.len),
        .source = source,
        .state = state,
    };
    @memcpy(value.title[0..title_value.len], title_value);
    return value;
}

pub fn titleSlice(value: *const SessionTitle) []const u8 {
    return value.title[0..value.title_len];
}
