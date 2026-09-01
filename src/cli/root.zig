//! Public command-line grammar and process entrypoints for the Telar executable.

const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

pub const agent = @import("agent.zig");
pub const api = @import("api.zig");
pub const client = @import("client.zig");
pub const config = @import("config.zig");
pub const control = @import("control.zig");
pub const pane = @import("pane.zig");
pub const skill = @import("skill.zig");
pub const history = @import("history.zig");
pub const hook = @import("hook.zig");
pub const integration = @import("integration.zig");
pub const notification = @import("notification.zig");
pub const plugin = @import("plugin.zig");
pub const server = @import("server.zig");

pub const AgentAction = parser.AgentAction;
pub const AgentOptions = parser.AgentOptions;
pub const ApiOptions = parser.ApiOptions;
pub const Cli = parser.Cli;
pub const HookOptions = parser.HookOptions;
pub const IntegrationOptions = parser.IntegrationOptions;
pub const PaneAction = parser.PaneAction;
pub const PaneOptions = parser.PaneOptions;
pub const Target = parser.Target;
pub const ConfigCheckOptions = parser.ConfigCheckOptions;
pub const HistoryAction = parser.HistoryAction;
pub const HistoryOptions = parser.HistoryOptions;
pub const NotificationOptions = parser.NotificationOptions;
pub const PluginCommand = parser.PluginCommand;
pub const PluginOptions = parser.PluginOptions;
pub const PluginWorkerOptions = parser.PluginWorkerOptions;
pub const RunOptions = parser.RunOptions;
pub const RuntimeConfigSelection = runtime_connection.RuntimeConfigSelection;
pub const RuntimeConnector = runtime_connection.RuntimeConnector;
pub const ServerAction = parser.ServerAction;
pub const ServerMode = parser.ServerMode;
pub const ServerOptions = parser.ServerOptions;
pub const max_args = parser.max_args;
pub const usage = @import("usage.zig").text;

test {
    _ = agent;
    _ = api;
    _ = client;
    _ = config;
    _ = control;
    _ = history;
    _ = hook;
    _ = integration;
    _ = notification;
    _ = pane;
    _ = parser;
    _ = plugin;
    _ = runtime_connection;
    _ = server;
    _ = skill;
}
