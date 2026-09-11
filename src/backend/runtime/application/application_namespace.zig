//! Runtime application state and cross-capability invariants.

const GenericCheckpointer = @import("GenericCheckpointer.zig").Type;
const Application = @import("Application.zig");
const GenericGitStatusObserver = @import("GenericGitStatusObserver.zig").Type;
const GenericSessionNameObserver = @import("GenericSessionNameObserver.zig").Type;
const GenericState = @import("../client/GenericState.zig").Type;
const SocketChannelType = @import("telar-core").SocketChannel;
const GenericEventDispatcher = @import("event_dispatcher/GenericEventDispatcher.zig").Type;
const GenericScheduler = @import("GenericScheduler.zig").Type;
const GenericDispatcher = @import("GenericDispatcher.zig").Type;
const runtime_event = @import("../event.zig");
const PaneFixtureType = @import("../tests/PaneFixture.zig");
const SessionType = @import("../client/Session.zig");
const StoreType = @import("../client/Store.zig");
const std = @import("std");
const encodeConfigureTerminalColors_module = @import("telar-core").encodeConfigureTerminalColors;
const decodeClient_module = @import("telar-core").decodeClient;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const ClientKey = @import("../../history/ClientKey.zig");
const state_support = @import("../../workspace/state_support.zig");

pub const SessionCheckpoint = GenericCheckpointer(Application);
pub const GitObserver = GenericGitStatusObserver(Application);
pub const SessionNameObserver = GenericSessionNameObserver(Application);

pub const ClientAdmissionState = GenericState(SocketChannelType);

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

pub const RuntimeEvents = GenericEventDispatcher(Application);
pub const Operations = GenericScheduler(Application);
pub const RequestDispatcher = GenericDispatcher(Application, Operations.request_runtime_port);
pub const EventResources = RuntimeEvents.EventResources;

/// Delegates one runtime event to the capability that owns it and reports
/// whether a requested shutdown has reached every client.
///
/// ```zig
/// const should_stop = try handle(&application, event, resources);
/// ```
pub fn handle(application: *Application, event: runtime_event.Event, resources: EventResources) !bool {
    return RuntimeEvents.handle(application, event, resources);
}

pub fn deinitWorkspaces(application: *Application) void {
    var repository = application.workspaceRepository();
    repository.deinit();
}

test "terminal colors follow workspace authority without letting spectators acquire it" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    const workspace = pane.location.workspace;
    var owner: SessionType = undefined;
    owner.key = .{ .id = 1, .generation = 1 };
    owner.terminal_colors = .{ .foreground = .{ 255, 255, 255 }, .background = .{ 16, 16, 16 } };
    owner.closing = true;
    var spectator: SessionType = undefined;
    spectator.key = .{ .id = 2, .generation = 1 };
    spectator.terminal_colors = .{ .background = .{ 240, 240, 240 } };
    spectator.closing = true;
    var clients: StoreType = .{};
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
    const declaration = try encodeConfigureTerminalColors_module(&wire_buffer, .{ .background = .{ 240, 240, 240 } });
    try application.dispatchClientMessage(&spectator, try decodeClient_module(declaration));
    application.refreshTerminalColors(spectator.key);
    try std.testing.expect(application.geometryOwner(workspace) == null);
    try std.testing.expect(pane.terminal.colors.background.get() == null);
    try std.testing.expect(application.holdsGeometry(owner.key, workspace));
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);
    try std.testing.expectEqualDeep(owner.terminal_colors, application.workspaceTerminalColors(workspace));
    const replacement = try encodeConfigureTerminalColors_module(&wire_buffer, .{ .foreground = .{ 255, 255, 255 }, .background = .{ 32, 32, 32 } });
    try application.dispatchClientMessage(&owner, try decodeClient_module(replacement));
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
    var clients: StoreType = .{};
    var application: Application = undefined;
    application.clients = &clients;
    application.geometry_leases = @splat(null);

    const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(7) };
    const owner: ClientKey = .{ .id = 3, .generation = 4 };
    const stale_owner: ClientKey = .{ .id = 3, .generation = 3 };

    try std.testing.expect(application.holdsGeometry(owner, workspace));
    try std.testing.expect(application.holdsGeometry(owner, workspace));
    try std.testing.expect(!application.holdsGeometry(stale_owner, workspace));

    application.releaseGeometryFor(owner, workspace);

    try std.testing.expect(application.holdsGeometry(stale_owner, workspace));
}

test "workspace geometry leases remain bounded by workspace capacity" {
    var clients: StoreType = .{};
    var application: Application = undefined;
    application.clients = &clients;
    application.geometry_leases = @splat(null);

    const owner: ClientKey = .{ .id = 1, .generation = 1 };
    for (0..state_support.max_workspaces) |index| {
        const workspace: WorkspaceLocationType = .{ .workspace = @enumFromInt(index + 1) };
        try std.testing.expect(application.holdsGeometry(owner, workspace));
    }

    const overflow: WorkspaceLocationType = .{ .workspace = @enumFromInt(state_support.max_workspaces + 1) };
    try std.testing.expect(!application.holdsGeometry(owner, overflow));
}

test {
    std.testing.refAllDecls(@This());
}
