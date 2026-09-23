const std = @import("std");
const limits = @import("agent_thread.zig");
const AgentEffort = @import("AgentEffort.zig");
const AgentOptions = @This();

model: [limits.max_model_bytes]u8 = @splat(0),
model_len: u8 = 0,
effort: AgentEffort = .{},
access: limits.Access = .workspace,

/// Example: `sendModel(options.modelSlice());`
pub fn modelSlice(self: *const AgentOptions) []const u8 {
    return self.model[0..self.model_len];
}

/// Owns the exact model identifier selected from a provider catalog. Example: `try options.setModel(model.idSlice());`
pub fn setModel(self: *AgentOptions, model: []const u8) !void {
    if (model.len == 0 or model.len > limits.max_model_bytes or !std.unicode.utf8ValidateSlice(model) or std.mem.indexOfScalar(u8, model, 0) != null) {
        return error.InvalidAgentModel;
    }

    @memcpy(self.model[0..model.len], model);
    self.model_len = @intCast(model.len);
}

/// Compares effective values without reading unused storage. Example: `if (options.eql(previous)) return;`
pub fn eql(self: AgentOptions, other: AgentOptions) bool {
    return self.access == other.access and self.effort.eql(other.effort) and std.mem.eql(u8, self.modelSlice(), other.modelSlice());
}

/// Validates a complete selection before it enters an outbound queue. Example: `if (!options.valid()) return error.InvalidAgentOptions;`
pub fn valid(self: *const AgentOptions) bool {
    if (self.model_len == 0 or self.model_len > limits.max_model_bytes or self.effort.id_len == 0 or self.effort.id_len > limits.max_effort_bytes) {
        return false;
    }

    return std.unicode.utf8ValidateSlice(self.modelSlice()) and std.mem.indexOfScalar(u8, self.modelSlice(), 0) == null and std.unicode.utf8ValidateSlice(self.effort.idSlice()) and std.mem.indexOfScalar(u8, self.effort.idSlice(), 0) == null;
}
