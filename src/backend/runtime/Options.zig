const GraphicsLimitsType = @import("../media/GraphicsLimits.zig");
const std = @import("std");
const FiltersType = @import("telar-core").Filters;
const Config = @import("../proxy/Config.zig");
const ServiceSpec = @import("../plugins/ServiceSpec.zig");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const OptionsType = @import("../engine/Options.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const IngestTestGate = @import("IngestTestGate.zig");
const LaunchTestFaultType = @import("application/LaunchTestFault.zig");
const Options = @This();

endpoint: []const u8,
graphics: GraphicsLimitsType = .{},
environment: std.process.Environ,
/// SQLite database for durable history; the default keeps it in memory.
history_path: [:0]const u8 = ":memory:",
/// Record-time history filtering: secrets refusal plus configured
/// command and cwd patterns.
history_filters: FiltersType = .{},
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
agent_manifests: TableType = builtin_table_module,
/// Absolute session checkpoint path; null keeps the session volatile.
session_path: ?[]const u8 = null,
/// Type each restored agent's resume command into its relaunched shell.
resume_agents: bool = true,
/// Test seam: stops the otherwise long-lived runtime without signals.
stop: ?*std.Io.Queue(u8) = null,
/// Test seam: holds a pane's ingest actor open.
ingest_gate: ?*IngestTestGate = null,
/// Test seam: fails one pane launch at a selected post-spawn phase.
launch_fault: ?*LaunchTestFaultType = null,
