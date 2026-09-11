const Options = @This();
const source_namespace = @import("config.zig");
const std = @import("std");
const core = @import("telar-core");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const IngestTestGate = @import("IngestTestGate.zig");
endpoint: []const u8,
graphics: source_namespace.GraphicsLimits = .{},
environment: std.process.Environ,
/// SQLite database for durable history; the default keeps it in memory.
history_path: [:0]const u8 = ":memory:",
/// Record-time history filtering: secrets refusal plus configured
/// command and cwd patterns.
history_filters: core.history_filter.Filters = .{},
/// Keep a bounded raw output tail per command (opt-in).
history_output_capture: bool = false,
proxy: ?source_namespace.ProxyOptions = null,
/// Whether the short-lived proxy authority is installed in system trust.
proxy_system_trusted: bool = false,
plugins: []const source_namespace.PluginSpec = &.{},
agent_descriptions: ?AgentDescriptionOptions = null,
/// The headless agent behind features like command suggestion.
engine: ?source_namespace.EngineOptions = null,
/// Agent identification rules; the built-in table unless configured.
agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
/// Absolute session checkpoint path; null keeps the session volatile.
session_path: ?[]const u8 = null,
/// Type each restored agent's resume command into its relaunched shell.
resume_agents: bool = true,
/// Test seam: stops the otherwise long-lived runtime without signals.
stop: ?*source_namespace.Io.Queue(u8) = null,
/// Test seam: holds a pane's ingest actor open.
ingest_gate: ?*IngestTestGate = null,
/// Test seam: fails one pane launch at a selected post-spawn phase.
launch_fault: ?*source_namespace.LaunchTestFault = null,
