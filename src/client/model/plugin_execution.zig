//! Owns one asynchronous reservation and rejects obsolete completions.
const std = @import("std");
const types = @import("types.zig");
const attachments = @import("../attachments/root.zig");
const PluginExecution = types.PluginExecution;
const PluginExecutionId = types.PluginExecutionId;
const ClipboardCapture = types.ClipboardCapture;
const ClipboardCaptureId = types.ClipboardCaptureId;

pub const State = struct {
    plugin_execution: ?PluginExecution = null,
    next_plugin_execution_id: u64 = 1,

    /// Example: `const result = state.pluginExecution(...);`.
    pub fn pluginExecution(state: *const State) ?PluginExecution {
        return state.plugin_execution;
    }

    /// Example: `const result = state.beginPluginExecution(...);`.
    pub fn beginPluginExecution(state: *State, configuration_generation: u64) !?PluginExecution {
        if (state.plugin_execution != null) {
            return null;
        }
        if (state.next_plugin_execution_id == 0) {
            return error.PluginExecutionIdExhausted;
        }

        const execution: PluginExecution = .{
            .id = @enumFromInt(state.next_plugin_execution_id),
            .configuration_generation = configuration_generation,
        };
        state.next_plugin_execution_id +%= 1;
        state.plugin_execution = execution;

        return execution;
    }

    /// Example: `const result = state.finishPluginExecution(...);`.
    pub fn finishPluginExecution(state: *State, id: PluginExecutionId) ?PluginExecution {
        const execution = state.plugin_execution orelse return null;
        if (execution.id != id) {
            return null;
        }

        state.plugin_execution = null;
        return execution;
    }
};
