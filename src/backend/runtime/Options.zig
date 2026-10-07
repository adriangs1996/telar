const core = @import("telar-core");
const GraphicsLimits = @import("../media/GraphicsLimits.zig");
const std = @import("std");
const Config = @import("../proxy/Config.zig");
const ServiceSpec = @import("../plugins/ServiceSpec.zig");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const pi_rpc = @import("pi_rpc");
const OptionsType = pi_rpc.Options;

endpoint: []const u8,
graphics: GraphicsLimits = .{},
environment: std.process.Environ,
/// SQLite database for durable history; the default keeps it in memory.
history_path: [:0]const u8 = ":memory:",
/// Record-time history filtering: secrets refusal plus configured
/// command and cwd patterns.
history_filters: core.Filters = .{},
/// Keep a bounded raw output tail per command (opt-in).
history_output_capture: bool = false,
proxy: ?Config = null,
/// Whether the short-lived proxy authority is installed in system trust.
proxy_system_trusted: bool = false,
plugins: []const ServiceSpec = &.{},
agent_descriptions: ?AgentDescriptionOptions = null,
/// The headless agent behind features like command suggestion.
engine: ?OptionsType = null,
/// Agent identification rules; the built-in table unless configured.
agent_manifests: core.Table = core.builtin_table,
/// The background runtime: once it holds the listener, its standard error
/// goes to `<endpoint>.runtime.log` (`RuntimeLog`).
own_log: bool = false,
/// Absolute session checkpoint path; null keeps the session volatile.
session_path: ?[]const u8 = null,
/// Type each restored agent's resume command into its relaunched shell.
resume_agents: bool = true,
