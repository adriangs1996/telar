const std = @import("std");
const limits = @import("agent_thread.zig");
const AgentEffort = @import("AgentEffort.zig");
const AgentModel = @This();

id: [limits.max_model_bytes]u8 = @splat(0),
id_len: u8 = 0,
label: [limits.max_model_label_bytes]u8 = @splat(0),
label_len: u8 = 0,
effort_storage: [limits.max_efforts]AgentEffort = @splat(.{}),
effort_count: u8 = 0,
default_effort: AgentEffort = .{},

/// Example: `sendModel(model.idSlice());`
pub fn idSlice(model: *const AgentModel) []const u8 {
    return model.id[0..model.id_len];
}

/// Example: `drawLabel(model.labelSlice());`
pub fn labelSlice(model: *const AgentModel) []const u8 {
    return model.label[0..model.label_len];
}

/// Example: `for (model.efforts()) |effort| drawEffort(effort);`
pub fn efforts(model: *const AgentModel) []const AgentEffort {
    return model.effort_storage[0..model.effort_count];
}

/// Example: `if (!model.supports(options.effort)) return error.UnsupportedEffort;`
pub fn supports(model: *const AgentModel, effort: AgentEffort) bool {
    if (effort.id_len > limits.max_effort_bytes) {
        return false;
    }

    for (model.efforts()) |supported| {
        if (std.mem.eql(u8, effort.idSlice(), supported.idSlice())) {
            return true;
        }
    }

    return false;
}
