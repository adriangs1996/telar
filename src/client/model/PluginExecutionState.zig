const State = @This();
const source_namespace = @import("plugin_execution.zig");
plugin_execution: ?source_namespace.PluginExecution = null,
next_plugin_execution_id: u64 = 1,

/// Example: `const result = state.pluginExecution(...);`.
pub fn pluginExecution(state: *const State) ?source_namespace.PluginExecution {
    return state.plugin_execution;
}

/// Example: `const result = state.beginPluginExecution(...);`.
pub fn beginPluginExecution(state: *State, configuration_generation: u64) !?source_namespace.PluginExecution {
    if (state.plugin_execution != null) {
        return null;
    }
    if (state.next_plugin_execution_id == 0) {
        return error.PluginExecutionIdExhausted;
    }

    const execution: source_namespace.PluginExecution = .{
        .id = @enumFromInt(state.next_plugin_execution_id),
        .configuration_generation = configuration_generation,
    };
    state.next_plugin_execution_id +%= 1;
    state.plugin_execution = execution;

    return execution;
}

/// Example: `const result = state.finishPluginExecution(...);`.
pub fn finishPluginExecution(state: *State, id: source_namespace.PluginExecutionId) ?source_namespace.PluginExecution {
    const execution = state.plugin_execution orelse return null;
    if (execution.id != id) {
        return null;
    }

    state.plugin_execution = null;
    return execution;
}
