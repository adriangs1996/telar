const model_data = @import("../model.zig");
const PluginExecution = @import("PluginExecution.zig");
const State = @This();

plugin_execution: ?PluginExecution = null,
next_plugin_execution_id: u64 = 1,

/// Example: `const result = state.pluginExecution(...);`.
pub fn pluginExecution(self: *const State) ?PluginExecution {
    return self.plugin_execution;
}

/// Example: `const result = state.beginPluginExecution(...);`.
pub fn beginPluginExecution(self: *State, configuration_generation: u64) !?PluginExecution {
    if (self.plugin_execution != null) {
        return null;
    }
    if (self.next_plugin_execution_id == 0) {
        return error.PluginExecutionIdExhausted;
    }

    const execution: PluginExecution = .{
        .id = @enumFromInt(self.next_plugin_execution_id),
        .configuration_generation = configuration_generation,
    };
    self.next_plugin_execution_id +%= 1;
    self.plugin_execution = execution;

    return execution;
}

/// Example: `const result = state.finishPluginExecution(...);`.
pub fn finishPluginExecution(self: *State, id: model_data.PluginExecutionId) ?PluginExecution {
    const execution = self.plugin_execution orelse return null;
    if (execution.id != id) {
        return null;
    }

    self.plugin_execution = null;
    return execution;
}
