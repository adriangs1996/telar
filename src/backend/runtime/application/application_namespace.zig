//! Runtime model state and cross-capability invariants.

const core = @import("telar-core");
const GenericCheckpointer = @import("GenericCheckpointer.zig").Type;
const RuntimeModel = @import("../RuntimeModel.zig");
const GenericGitStatusObserver = @import("GenericGitStatusObserver.zig").Type;
const GenericSessionNameObserver = @import("GenericSessionNameObserver.zig").Type;
const GenericState = @import("../client/GenericState.zig").Type;
const runtime_event = @import("../event.zig");
const PaneFixtureType = @import("../tests/PaneFixture.zig");
const SessionType = @import("../client/Session.zig");
const std = @import("std");
const ClientKey = @import("../../history/ClientKey.zig");
const state_support = @import("../../workspace/state_support.zig");

pub const SessionCheckpoint = GenericCheckpointer(RuntimeModel);
pub const GitObserver = GenericGitStatusObserver(RuntimeModel);
pub const SessionNameObserver = GenericSessionNameObserver(RuntimeModel);

pub const ClientAdmissionState = GenericState(core.SocketChannel);

pub const RequestDispatcher = @import("requests.zig");

pub fn deinitWorkspaces(model: *RuntimeModel) void {
    var repository = model.workspaceRepository();
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
    var model: RuntimeModel = undefined;
    model.clients = .{};
    model.clients.items[0] = &owner;
    model.clients.items[1] = &spectator;
    model.geometry_leases = @splat(null);
    model.panes = .{};
    model.workspaces = .{};
    model.gpa = std.testing.allocator;
    try model.panes.insert(pane);

    var wire_buffer: [16]u8 = undefined;
    const declaration = try core.encodeConfigureTerminalColors(&wire_buffer, .{ .background = .{ 240, 240, 240 } });
    try model.dispatchClientMessage(&spectator, try core.decodeClient(declaration));
    model.refreshTerminalColors(spectator.key);
    try std.testing.expect(model.geometryOwner(workspace) == null);
    try std.testing.expect(pane.terminal.colors.background.get() == null);
    try std.testing.expect(model.holdsGeometry(owner.key, workspace));
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);
    try std.testing.expectEqualDeep(owner.terminal_colors, model.workspaceTerminalColors(workspace));
    const replacement = try core.encodeConfigureTerminalColors(&wire_buffer, .{ .foreground = .{ 255, 255, 255 }, .background = .{ 32, 32, 32 } });
    try model.dispatchClientMessage(&owner, try core.decodeClient(replacement));
    try std.testing.expectEqual(@as(u8, 32), pane.terminal.colors.background.default.?.r);
    owner.terminal_colors.background = .{ 16, 16, 16 };
    model.refreshTerminalColors(owner.key);
    model.refreshTerminalColors(spectator.key);
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);

    pane.stream.nextSlice("\x1b]11;rgb:12/34/56\x07");
    model.releaseGeometryFor(owner.key, workspace);
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.default.?.r);
    try std.testing.expect(model.holdsGeometry(spectator.key, workspace));
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.default.?.r);
    try std.testing.expectEqual(@as(u8, 0x12), pane.terminal.colors.background.get().?.r);
    pane.stream.nextSlice("\x1b]111\x07");
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);

    model.refreshTerminalColors(.{ .id = spectator.key.id, .generation = 2 });
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);
}

test "a workspace geometry lease is exclusive to one client generation" {
    var model: RuntimeModel = undefined;
    model.clients = .{};
    model.geometry_leases = @splat(null);

    const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(7) };
    const owner: ClientKey = .{ .id = 3, .generation = 4 };
    const stale_owner: ClientKey = .{ .id = 3, .generation = 3 };

    try std.testing.expect(model.holdsGeometry(owner, workspace));
    try std.testing.expect(model.holdsGeometry(owner, workspace));
    try std.testing.expect(!model.holdsGeometry(stale_owner, workspace));

    model.releaseGeometryFor(owner, workspace);

    try std.testing.expect(model.holdsGeometry(stale_owner, workspace));
}

test "workspace geometry leases remain bounded by workspace capacity" {
    var model: RuntimeModel = undefined;
    model.clients = .{};
    model.geometry_leases = @splat(null);

    const owner: ClientKey = .{ .id = 1, .generation = 1 };
    for (0..state_support.max_workspaces) |index| {
        const workspace: core.WorkspaceLocation = .{ .workspace = @enumFromInt(index + 1) };
        try std.testing.expect(model.holdsGeometry(owner, workspace));
    }

    const overflow: core.WorkspaceLocation = .{ .workspace = @enumFromInt(state_support.max_workspaces + 1) };
    try std.testing.expect(!model.holdsGeometry(owner, overflow));
}

test {
    std.testing.refAllDecls(@This());
}
