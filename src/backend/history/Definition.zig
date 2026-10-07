const core = @import("telar-core");
const model = @import("model.zig");

id: model.SessionId,
title: []const u8,
source: core.AgentTitleSource,
state: core.AgentTitleState,
