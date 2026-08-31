//! Public command-line grammar for the Telar executable.

const parser = @import("parser.zig");

pub const Cli = parser.Cli;
pub const ConfigCheckOptions = parser.ConfigCheckOptions;
pub const HistoryAction = parser.HistoryAction;
pub const HistoryOptions = parser.HistoryOptions;
pub const NotificationOptions = parser.NotificationOptions;
pub const PluginCommand = parser.PluginCommand;
pub const PluginOptions = parser.PluginOptions;
pub const PluginWorkerOptions = parser.PluginWorkerOptions;
pub const RunOptions = parser.RunOptions;
pub const ServerAction = parser.ServerAction;
pub const ServerMode = parser.ServerMode;
pub const ServerOptions = parser.ServerOptions;
