const core = @import("telar-core");
const model = @import("model.zig");
const Definition = @This();

id: model.SessionId,
title: []const u8,
source: core.AgentTitleSource,
state: core.AgentTitleState,
