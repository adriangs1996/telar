const std = @import("std");
const limits = @import("agent_thread.zig");
const AgentEffort = @import("AgentEffort.zig");
const AgentOptions = @This();

model: [limits.max_model_bytes]u8 = @splat(0),
model_len: u8 = 0,
effort: AgentEffort = .{},
access: limits.Access = .workspace,

/// Example: `sendModel(options.modelSlice());`
pub fn modelSlice(options: *const AgentOptions) []const u8 {
    return options.model[0..options.model_len];
}

/// Owns the exact model identifier selected from a provider catalog. Example: `try options.setModel(model.idSlice());`
pub fn setModel(options: *AgentOptions, model: []const u8) !void {
    if (model.len == 0 or model.len > limits.max_model_bytes or !std.unicode.utf8ValidateSlice(model) or std.mem.indexOfScalar(u8, model, 0) != null) {
        return error.InvalidAgentModel;
    }

    @memcpy(options.model[0..model.len], model);
    options.model_len = @intCast(model.len);
}

/// Compares effective values without reading unused storage. Example: `if (options.eql(previous)) return;`
pub fn eql(options: AgentOptions, other: AgentOptions) bool {
    return options.access == other.access and options.effort.eql(other.effort) and std.mem.eql(u8, options.modelSlice(), other.modelSlice());
}

/// Validates a complete selection before it enters an outbound queue. Example: `if (!options.valid()) return error.InvalidAgentOptions;`
pub fn valid(options: *const AgentOptions) bool {
    if (options.model_len == 0 or options.model_len > limits.max_model_bytes or options.effort.id_len == 0 or options.effort.id_len > limits.max_effort_bytes) {
        return false;
    }

    return std.unicode.utf8ValidateSlice(options.modelSlice()) and std.mem.indexOfScalar(u8, options.modelSlice(), 0) == null and std.unicode.utf8ValidateSlice(options.effort.idSlice()) and std.mem.indexOfScalar(u8, options.effort.idSlice(), 0) == null;
}
