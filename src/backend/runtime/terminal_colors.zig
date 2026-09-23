//! A workspace's panes use the default colors of the client that holds its
//! geometry lease. Spectators declare colors but never impose them.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientKey = @import("../history/ClientKey.zig");
const geometry_lease = @import("geometry_lease.zig");
const client_request = @import("client_request.zig");
const PaneFixture = @import("tests/PaneFixture.zig");

/// Receives a client's declared colors and applies them where it holds the
/// geometry lease.
///
/// ```zig
/// terminal_colors.configure(model, session, colors);
/// ```
pub fn configure(model: *RuntimeModel, session: *Session, colors: core.TerminalColors) void {
    if (!session.setTerminalColors(colors)) {
        return;
    }

    var rows = model.workspaces.reserved.iterator(.{});
    while (rows.next()) |slot| {
        const holder = model.workspaces.lease[slot] orelse continue;
        if (std.meta.eql(holder, session.key)) {
            apply(model, .{ .workspace = model.workspaces.id[slot] }, session.key);
        }
    }
}

/// The colors a new pane in `workspace` starts with.
/// Example: `const colors = terminal_colors.ofWorkspace(model, location.workspace);`.
pub fn ofWorkspace(model: *RuntimeModel, workspace: core.WorkspaceLocation) core.TerminalColors {
    const holder = geometry_lease.owner(model, workspace) orelse return .{};
    const session = model.clients.resolve(holder) orelse return .{};
    return session.terminal_colors;
}

/// Sets the lease holder's colors on every pane of the workspace.
/// Example: `terminal_colors.apply(model, workspace, holder);`.
pub fn apply(model: *RuntimeModel, workspace: core.WorkspaceLocation, key: ClientKey) void {
    const session = model.clients.resolve(key) orelse return;
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location.workspace, workspace)) {
            pane.setTerminalColors(session.terminal_colors);
        }
    }
}

test "terminal colors follow workspace authority without letting spectators acquire it" {
    const fixture = try std.testing.allocator.create(PaneFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();
    const pane = fixture.pane;
    const workspace = pane.location.workspace;
    var owner: Session = undefined;
    owner.key = .{ .id = 1, .generation = 1 };
    owner.terminal_colors = .{ .foreground = .{ 255, 255, 255 }, .background = .{ 16, 16, 16 } };
    owner.closing = true;
    var spectator: Session = undefined;
    spectator.key = .{ .id = 2, .generation = 1 };
    spectator.terminal_colors = .{ .background = .{ 240, 240, 240 } };
    spectator.closing = true;
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.clients = .{};
    model.clients.items[0] = &owner;
    model.clients.items[1] = &spectator;
    model.panes = .{};
    model.workspaces = .{};
    defer model.workspaces.deinit(std.testing.allocator);
    model.gpa = std.testing.allocator;
    try model.panes.insert(pane);
    _ = try model.workspaces.restore(std.testing.allocator, .{
        .id = workspace.workspace,
        .path = "/work/telar",
        .explicit_name = null,
        .first_tab_id = pane.location.tab_id,
        .first_tab_label = "",
    });

    var wire_buffer: [16]u8 = undefined;
    const declaration = try core.encodeConfigureTerminalColors(&wire_buffer, .{ .background = .{ 240, 240, 240 } });
    try client_request.receive(model, &spectator, try core.decodeClient(declaration));
    try std.testing.expect(geometry_lease.owner(model, workspace) == null);
    try std.testing.expect(pane.terminal.colors.background.get() == null);
    try std.testing.expect(geometry_lease.acquire(model, owner.key, workspace));
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);
    try std.testing.expectEqualDeep(owner.terminal_colors, ofWorkspace(model, workspace));
    const replacement = try core.encodeConfigureTerminalColors(&wire_buffer, .{ .foreground = .{ 255, 255, 255 }, .background = .{ 32, 32, 32 } });
    try client_request.receive(model, &owner, try core.decodeClient(replacement));
    try std.testing.expectEqual(@as(u8, 32), pane.terminal.colors.background.default.?.r);
    owner.terminal_colors.background = .{ 17, 17, 17 };
    configure(model, &owner, .{ .foreground = .{ 255, 255, 255 }, .background = .{ 16, 16, 16 } });
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.get().?.r);

    pane.stream.nextSlice("\x1b]11;rgb:12/34/56\x07");
    geometry_lease.release(model, owner.key, workspace);
    try std.testing.expectEqual(@as(u8, 16), pane.terminal.colors.background.default.?.r);
    try std.testing.expect(geometry_lease.acquire(model, spectator.key, workspace));
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.default.?.r);
    try std.testing.expectEqual(@as(u8, 0x12), pane.terminal.colors.background.get().?.r);
    pane.stream.nextSlice("\x1b]111\x07");
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);

    var stale = spectator;
    stale.key.generation = 2;
    stale.terminal_colors = .{ .background = .{ 1, 1, 1 } };
    configure(model, &stale, .{ .background = .{ 2, 2, 2 } });
    try std.testing.expectEqual(@as(u8, 240), pane.terminal.colors.background.get().?.r);
}
