const AgentSkill = @import("AgentSkill.zig");
name: []const u8,
label: []const u8 = "",
description: []const u8 = "",
scope: AgentSkill.Scope = .user,
