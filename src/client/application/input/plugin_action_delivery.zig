//! Application policy for delivering one classified plugin action outcome.

const plugin_action = @import("plugin_action.zig");
const FailurePublication = @import("FailurePublication.zig");
const client_diagnostic = @import("../configuration/client_diagnostic.zig");
const std = @import("std");

pub fn startFailurePublication(outcome: plugin_action.StartOutcome) ?FailurePublication {
    return switch (outcome) {
        .started, .busy, .unavailable => null,
        .rejected => |err| .{
            .diagnostic = client_diagnostic.formatted(
                "plugin action cannot be resolved: {s}",
                .{@errorName(err)},
            ),
            .title = "Plugin action rejected",
        },
    };
}

pub fn completionFailurePublication(outcome: plugin_action.CompletionOutcome) ?FailurePublication {
    return switch (outcome) {
        .applied, .exit, .stale, .ignored => null,
        .worker_failed => |err| .{
            .diagnostic = client_diagnostic.formatted("plugin worker failed: {s}", .{@errorName(err)}),
            .title = "Plugin failed",
        },
        .authorization_failed => |err| if (err == error.PluginRegistryUnavailable) .{
            .diagnostic = client_diagnostic.formatted(
                "plugin registry changed while action was running",
                .{},
            ),
            .title = "Plugin failed",
        } else .{
            .diagnostic = client_diagnostic.formatted("plugin effect denied: {s}", .{@errorName(err)}),
            .title = "Plugin denied",
        },
    };
}
