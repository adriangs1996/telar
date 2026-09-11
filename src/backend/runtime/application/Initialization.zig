const Initialization = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
const history = @import("../../history/root.zig");
const pty = @import("../../pty/root.zig");
const core = @import("telar-core");
const proxy_resource = @import("../resources/proxy.zig");
const plugins = @import("../../plugins/root.zig");
const engine = @import("../../engine/root.zig");
const runtime_config = @import("../config.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
heap: *source_namespace.diagnostics.Heap,
select: *source_namespace.Io.Select(source_namespace.RuntimeEvent),
history_service: *history.Service,
child_environment: *const pty.ChildEnvironment,
inherited_environment: std.process.Environ,
socket_path: []const u8,
agent_manifests: *const core.agent_manifest.Table,
proxy_runtime: *proxy_resource.Runtime,
plugin_service: *plugins.Service,
agent_description_options: ?source_namespace.AgentDescriptionOptions,
engine_service: ?*engine.Service = null,
launch_fault: ?*source_namespace.LaunchTestFault,
clients: *source_namespace.ClientStore,
graphics: runtime_config.GraphicsLimits,
session_path: ?[]const u8 = null,
resume_agents: bool = true,
