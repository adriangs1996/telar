//! Public command-line grammar for the Telar executable.

const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

pub const client = @import("client.zig");
pub const config = @import("config.zig");
pub const history = @import("history.zig");
pub const notification = @import("notification.zig");
pub const plugin = @import("plugin.zig");

pub const Cli = parser.Cli;
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
