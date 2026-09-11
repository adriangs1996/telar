//! Runtime application state and cross-capability invariants.

const std = @import("std");
const core = @import("telar-core");
const coordinators = @import("coordinators/root.zig");
pub const agent_description_coordinator = coordinators.agent_description;
const history = @import("../../history/root.zig");
const engine = @import("../../engine/root.zig");
const plugins = @import("../../plugins/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const client_mod = @import("../client/root.zig");
const runtime_config = @import("../config.zig");
const delivery = @import("../delivery/root.zig");
const runtime_event = @import("../event.zig");
const pane_launcher = @import("pane_launcher.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const git_status = @import("git_status.zig");
const session_name = @import("session_name.zig");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const model = @import("model.zig");
const pty = @import("../../pty/root.zig");
const shutdown = @import("../lifecycle/root.zig").shutdown_authority;
const proxy_resource = @import("../resources/proxy.zig");
const observability = @import("../observability/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const event_dispatcher = @import("event_dispatcher/root.zig");
const operation_scheduler = @import("operation_scheduler.zig");
const request_dispatch = @import("request_dispatch.zig");

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;
pub const Pane = pane_mod.Pane;
pub const PaneLauncher = pane_launcher.PaneLauncher;
pub const SessionCheckpoint = session_checkpoint.Checkpointer(Application);
pub const GitObserver = git_status.Observer(Application);
pub const SessionNameObserver = session_name.Observer(Application);
pub const WorkspaceRepository = workspace_mod.Repository;
pub const RuntimeModel = model.RuntimeModel;
pub const ClientAdmissionState = client_mod.admission.State(core.transport.SocketChannel);
pub const RuntimeMetrics = observability.telemetry.RuntimeMetrics;
pub const AgentDescriptionOptions = runtime_config.AgentDescriptionOptions;
pub const LaunchTestFault = runtime_config.LaunchTestFault;
pub const ClientKey = client_mod.session.Key;
pub const ClientSession = client_mod.session.Session;
pub const ClientStore = client_mod.store.Store;
pub const RuntimeEvent = runtime_event.Event;
pub const PendingNotification = delivery.PendingNotification;
pub const max_workspaces = workspace_mod.max_workspaces;

const GeometryLease = @import("GeometryLease.zig");

const WorkspaceChange = @import("WorkspaceChange.zig");

pub const Initialization = @import("Initialization.zig");

pub const ShutdownStep = enum {
    stop_client_connections,
    stop_pending_admission,
    stop_panes,
    destroy_pending_admission,
    release_client_actor_claims,
    destroy_client_sessions,
    destroy_panes,
    destroy_workspaces,
};

pub const Application = @import("Application.zig");

pub const RuntimeEvents = event_dispatcher.Dispatcher(Application);
pub const Operations = operation_scheduler.Scheduler(Application);
pub const RequestDispatcher = request_dispatch.Dispatcher(Application, Operations.request_runtime_port);
pub const EventResources = RuntimeEvents.EventResources;

/// Delegates one runtime event to the capability that owns it and reports
/// whether a requested shutdown has reached every client.
///
/// ```zig
/// const should_stop = try handle(&application, event, resources);
/// ```
pub fn handle(application: *Application, event: RuntimeEvent, resources: EventResources) !bool {
    return RuntimeEvents.handle(application, event, resources);
}

pub fn deinitWorkspaces(application: *Application) void {
    var repository = application.workspaceRepository();
    repository.deinit();
}

test "terminal colors follow workspace authority without letting spectators acquire it" {
    var fixture: @import("../tests/support.zig").PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    const workspace = pane.location.workspace;
    var owner: ClientSession = undefined;
    owner.key = .{ .id = 1, .generation = 1 };
    owner.terminal_colors = .{ .foreground = .{ 255, 255, 255 }, .background = .{ 16, 16, 16 } };
    owner.closing = true;
    var spectator: ClientSession = undefined;
    spectator.key = .{ .id = 2, .generation = 1 };
    spectator.terminal_colors = .{ .background = .{ 240, 240, 240 } };
    spectator.closing = true;
    var clients: ClientStore = .{};
    clients.items[0] = &owner;
    clients.items[1] = &spectator;
    var application: Application = undefined;
    application.clients = &clients;
    application.geometry_leases = @splat(null);
    application.model.panes = .{};
    application.model.workspaces = .{};
    application.gpa = std.testing.allocator;
    try application.model.panes.insert(pane);

    var wire_buffer: [16]u8 = undefined;
    const declaration = try schema.encodeConfigureTerminalColors(&wire_buffer, .{ .background = .{ 240, 240, 240 } });
    try application.dispatchClientMessage(&spectator, try schema.decodeClient(declaration));
    application.refreshTerminalColors(spectator.key);
    try std.testing.expect(application.geometryOwner(workspace) == null);
    try std.testing.expect(pane.terminal.colors.background.get() == null);
    try std.testing.expect(application.holdsGeometry(owner.key, workspace));
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);
    try std.testing.expectEqualDeep(owner.terminal_colors, application.workspaceTerminalColors(workspace));
    const replacement = try schema.encodeConfigureTerminalColors(&wire_buffer, .{ .foreground = .{ 255, 255, 255 }, .background = .{ 32, 32, 32 } });
    try application.dispatchClientMessage(&owner, try schema.decodeClient(replacement));
    try std.testing.expectEqual(@as(u8, 32), pane.terminal.colors.background.default.?.r);
    owner.terminal_colors.background = .{ 16, 16, 16 };
    application.refreshTerminalColors(owner.key);
    application.refreshTerminalColors(spectator.key);
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);

    pane.stream.nextSlice("\x1b]11;rgb:12/34/56\x07");
    application.releaseGeometryFor(owner.key, workspace);
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.default.?.r);
    try std.testing.expect(application.holdsGeometry(spectator.key, workspace));
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.default.?.r);
    try std.testing.expectEqual(@as(u8, 0x12), pane.terminal.colors.background.get().?.r);
    pane.stream.nextSlice("\x1b]111\x07");
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);

    application.refreshTerminalColors(.{ .id = spectator.key.id, .generation = 2 });
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);
}

test "a workspace geometry lease is exclusive to one client generation" {
    var clients: ClientStore = .{};
    var application: Application = undefined;
    application.clients = &clients;
    application.geometry_leases = @splat(null);

    const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const owner: ClientKey = .{ .id = 3, .generation = 4 };
    const stale_owner: ClientKey = .{ .id = 3, .generation = 3 };

    try std.testing.expect(application.holdsGeometry(owner, workspace));
    try std.testing.expect(application.holdsGeometry(owner, workspace));
    try std.testing.expect(!application.holdsGeometry(stale_owner, workspace));

    application.releaseGeometryFor(owner, workspace);

    try std.testing.expect(application.holdsGeometry(stale_owner, workspace));
}

test "workspace geometry leases remain bounded by workspace capacity" {
    var clients: ClientStore = .{};
    var application: Application = undefined;
    application.clients = &clients;
    application.geometry_leases = @splat(null);

    const owner: ClientKey = .{ .id = 1, .generation = 1 };
    for (0..max_workspaces) |index| {
        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(index + 1) };
        try std.testing.expect(application.holdsGeometry(owner, workspace));
    }

    const overflow: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(max_workspaces + 1) };
    try std.testing.expect(!application.holdsGeometry(owner, overflow));
}

test {
    std.testing.refAllDecls(@This());
}
