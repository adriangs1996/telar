const core = @import("telar-core");
const std = @import("std");
const event = @import("../event.zig");
const ServiceType = @import("../../history/Service.zig");
const ChildEnvironmentType = @import("../../pty/ChildEnvironment.zig");
const ProxyRuntime = @import("../resources/ProxyRuntime.zig");
const PluginsService = @import("../../plugins/Service.zig");
const AgentDescriptionOptionsType = @import("../AgentDescriptionOptions.zig");
const EngineService = @import("../../engine/Service.zig");
const LaunchTestFaultType = @import("LaunchTestFault.zig");
const Store = @import("../client/Store.zig");
const GraphicsLimitsType = @import("../../media/GraphicsLimits.zig");
const Initialization = @This();

io: std.Io,
gpa: std.mem.Allocator,
heap: *core.Heap,
select: *std.Io.Select(event.Event),
history_service: *ServiceType,
child_environment: *const ChildEnvironmentType,
inherited_environment: std.process.Environ,
socket_path: []const u8,
agent_manifests: *const core.Table,
proxy_runtime: *ProxyRuntime,
plugin_service: *PluginsService,
agent_description_options: ?AgentDescriptionOptionsType,
engine_service: ?*EngineService = null,
launch_fault: ?*LaunchTestFaultType,
clients: *Store,
graphics: GraphicsLimitsType,
session_path: ?[]const u8 = null,
resume_agents: bool = true,
