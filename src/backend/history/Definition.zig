const model = @import("model.zig");
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const Definition = @This();

id: model.SessionId,
title: []const u8,
source: AgentTitleSourceType,
state: AgentTitleStateType,
