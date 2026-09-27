const localsocket = @import("localsocket");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Fixture = @import("ChromeFixture.zig");
const host_ports = @import("../host_ports.zig");
const window_machines = @import("../window_machines.zig");

const Machines = client.Machines;

const Peer = struct {
    channel: localsocket.SocketChannel,
    peer: localsocket.SocketChannel,
};

fn socketPair() !Peer {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .channel = .init(.{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } }),
        .peer = .init(.{ .socket = .{ .handle = fds[1], .address = .{ .ip4 = .loopback(0) } } }),
    };
}

// Opens a second machine's client over `connection`, hidden, the way the
// window opens a saved machine once it is connected.
fn openMachine(session: *Session, connection: *localsocket.SocketChannel) !u8 {
    const gui = session.gui;
    const own = window_machines.window(gui);
    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    gui.machines.live[Machines.local_slot] = true;
    const slot = try gui.machines.add(.{ .label = "box", .destination = "dev@box" }, null);

    const app = &gui.clients[slot];
    try client.Client.init(app, .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = connection,
        .host_size = own.model.host.host_size,
        .window_width_px = own.model.host.host_capabilities.window_width_px,
        .window_height_px = own.model.host.host_capabilities.window_height_px,
        .options = .{
            .arguments = &.{"/bin/sh"},
            .cwd = "/",
            .endpoint = "",
        },
    });
    gui.machines.live[slot] = true;
    app.graphics = host_ports.graphicsRetention(gui);
    app.chrome = host_ports.chrome(gui);
    app.host_input_source = host_ports.hostInput(gui);
    app.presented = false;
    app.machines = &gui.machines;
    return slot;
}

test "the next machine is shown and the window's own leaves its workspace once idle" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    const own = window_machines.window(gui);
    try std.testing.expect(own.model.workspace != null);

    try window_machines.choose(gui, .{ .offset = 1 });
    try std.testing.expect(gui.app == &gui.clients[slot]);
    try std.testing.expectEqual(slot, gui.machines.active);
    try std.testing.expect(gui.app.presented);
    try std.testing.expect(!own.presented);

    // The workspace's snapshot requests are still in flight, so leaving
    // waits for their replies.
    try std.testing.expect(own.leave_pending);
    try std.testing.expect(own.model.workspace != null);
    own.model.request_lifecycle = .{};
    try client.machine_presentation.settle(own);
    try std.testing.expect(!own.leave_pending);
    try std.testing.expect(own.model.workspace == null);
    try std.testing.expectEqual(@as(?core.WorkspaceId, Session.location.workspace.workspace), own.left_workspace);

    try window_machines.choose(gui, .{ .offset = 1 });
    try std.testing.expect(gui.app == own);
    try std.testing.expect(own.presented);
    try std.testing.expect(own.left_workspace == null);
    try std.testing.expect(own.model.to_runtime.len != 0);
}

test "a machine chosen while a frame is in flight is shown after it" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);

    _ = try session.draw();
    try std.testing.expect(gui.app.presentation.active != null);
    try window_machines.choose(gui, .{ .slot = slot });
    try std.testing.expect(gui.app == window_machines.window(gui));
    try std.testing.expectEqual(@as(?u8, slot), gui.pending_machine);
}

test "the top bar names the machine only while the window holds several" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.measure(.{ .width = 900, .height = 600, .scale = 1 });
    const gui = fixture.session.gui;

    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    var projection = fixture.projection();
    projection.machines = &gui.machines;
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.machine_picker) == null);

    _ = try gui.machines.add(.{ .label = "box", .destination = "dev@box", .color = "red" }, null);
    projection = fixture.projection();
    projection.machines = &gui.machines;
    try fixture.paint(projection);
    const segment = fixture.bandTarget(.machine_picker).?;
    try std.testing.expect(segment.width > 0);
    const command = fixture.clickBand(segment, 0);
    try std.testing.expect(command.intent == .machine_picker);
}

test "the expanded sidebar switches between machines and folds the rest" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.measure(.{ .width = 1100, .height = 700, .scale = 1 });
    try fixture.showSidebar(true);
    const gui = fixture.session.gui;

    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    const box = try gui.machines.add(.{ .label = "box", .destination = "dev@box" }, null);
    _ = try gui.machines.add(.{ .label = "gpu", .destination = "dev@gpu" }, null);
    var projection = fixture.projection();
    projection.machines = &gui.machines;
    try fixture.paint(projection);

    const control = fixture.bandTarget(.{ .select_machine = box }).?;
    const command = fixture.clickBand(control, 0);
    try std.testing.expect(command.intent == .select_machine and command.intent.select_machine == box);
    try std.testing.expect(fixture.bandTarget(.machine_picker) != null);

    var index: usize = 0;
    while (index < 10) : (index += 1) {
        var label_buffer: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "machine-{d}", .{index});
        _ = try gui.machines.add(.{ .label = label, .destination = label }, null);
    }

    projection = fixture.projection();
    projection.machines = &gui.machines;
    try fixture.paint(projection);
    try std.testing.expect(fixture.bandTarget(.{ .select_machine = @intCast(gui.machines.count() - 1) }) == null);
}
