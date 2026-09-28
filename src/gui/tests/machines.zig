const localsocket = @import("localsocket");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const Session = @import("Session.zig");
const Fixture = @import("ChromeFixture.zig");
const gui_event = @import("../gui_event.zig");
const host_ports = @import("../host_ports.zig");
const window_machines = @import("../window_machines.zig");

const Machines = client.Machines;
const runtime_link = client.runtime_link;

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
    if (!gui.machines.used[Machines.local_slot]) {
        _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
        gui.machines.live[Machines.local_slot] = true;
    }

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
    app.graphics = host_ports.graphicsRetention(gui, slot);
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
    try std.testing.expectEqual(@as(?core.WorkspaceLocation, Session.location.workspace), own.left_workspace);

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

test "a machine hidden in a worktree reopens that worktree when shown again" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrapAt(.{
        .workspace = .{
            .worktree = @enumFromInt(3),
        },
        .tab_id = @enumFromInt(1),
    });
    const gui = session.gui;

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    _ = try openMachine(session, &box.channel);
    const own = window_machines.window(gui);

    try window_machines.choose(gui, .{ .offset = 1 });
    own.model.request_lifecycle = .{};
    try client.machine_presentation.settle(own);
    try std.testing.expect(own.model.workspace == null);
    const left: core.WorkspaceLocation = .{
        .worktree = @enumFromInt(3),
    };
    try std.testing.expectEqual(@as(?core.WorkspaceLocation, left), own.left_workspace);

    try window_machines.choose(gui, .{ .offset = 1 });
    try std.testing.expect(gui.app == own);
    try std.testing.expect(own.left_workspace == null);
    try std.testing.expect(!own.model.request_lifecycle.tracker.isEmpty());
}

test "a hidden machine never hides the shown machine's pane graphics" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    const own = window_machines.window(gui);

    // Both runtimes number their panes from the same start, so the hidden
    // machine's pane can carry the id of the shown one's.
    try gui.clients[slot].graphics.setPaneVisible(Session.pane_id, false);
    try std.testing.expect(own.graphics.paneVisible(Session.pane_id));
    try std.testing.expect(!gui.clients[slot].graphics.paneVisible(Session.pane_id));
}

test "sixteen machines reading their runtimes fit in the window's inbox" {
    // The reads in flight hold the sockets until the window cancels them,
    // so the sockets close after the window.
    var peers: [Machines.capacity - 1]Peer = undefined;
    for (&peers) |*peer| {
        peer.* = try socketPair();
    }

    defer for (&peers) |*peer| {
        peer.channel.deinit(std.testing.io);
        peer.peer.deinit(std.testing.io);
    };

    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;

    for (&peers) |*peer| {
        const slot = try openMachine(session, &peer.channel);
        const app = &gui.clients[slot];
        try client.runtime_io.startRuntimeIo(app);
        try client.notifications.publishNotificationNow(app, .{
            .title = "agent finished",
            .message = "box",
        });
    }

    try window_machines.startJobs(gui);
    const tickets = gui.driver.inbox.snapshot();
    for (gui.clients[1..Machines.capacity]) |*app| {
        try std.testing.expectEqual(data.RuntimeLink.Phase.connected, app.model.runtime_link.phase);
    }

    // Each machine holds its read and its notification's wait, well within
    // what each adds to the window's inbox.
    try std.testing.expectEqual(@as(u64, 0), tickets.rejected);
    try std.testing.expect(tickets.high_water >= peers.len);
    try std.testing.expect(tickets.high_water <= peers.len * gui_event.Message.tickets_per_machine);
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

// Points the window at a `machines.json` in `temp` and writes `profiles`
// there, the way `telar machine` replaces it.
fn saveProfiles(session: *Session, temp: *std.testing.TmpDir, profiles: *const core.MachineProfiles) !void {
    const gui = session.gui;
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    const path = try std.fmt.bufPrint(&gui.profiles_path, "{s}/telar/{s}", .{ directory_buffer[0..directory_len], client.profile_file.file_name });
    gui.profiles_path_len = path.len;

    try client.profile_file.save(std.testing.io, path, profiles);
}

fn boxProfile(destination: []const u8, enabled: bool) !core.MachineProfiles {
    var profiles: core.MachineProfiles = .{};
    var profile = try core.MachineProfile.init(@enumFromInt(7), .{
        .label = "box",
        .destination = destination,
    });
    profile.enabled = enabled;
    try profiles.add(profile);
    return profiles;
}

// A configuration home in a temporary directory for the window's own
// client, so `machines.json` resolves inside it.
const ConfigHome = struct {
    temp: std.testing.TmpDir,
    environment: std.process.Environ.Map,
    block: std.process.Environ.PosixBlock,

    fn open(self: *ConfigHome, app: *client.Client) !void {
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();

        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_len = try self.temp.dir.realPath(std.testing.io, &directory_buffer);
        self.environment = std.process.Environ.Map.init(std.testing.allocator);
        errdefer self.environment.deinit();

        try self.environment.put("XDG_CONFIG_HOME", directory_buffer[0..directory_len]);
        try self.environment.put("HOME", directory_buffer[0..directory_len]);
        self.block = try self.environment.createPosixBlock(std.testing.allocator, .{});
        app.options.environ = .{ .block = self.block };
    }

    fn close(self: *ConfigHome) void {
        self.block.deinit(std.testing.allocator);
        self.environment.deinit();
        self.temp.cleanup();
    }
};

test "a machine opened by name stays open until its own profile is disabled" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const own = window_machines.window(gui);

    var home: ConfigHome = undefined;
    try home.open(own);
    defer home.close();

    var profiles = try boxProfile("dev@box", false);
    try saveProfiles(session, &home.temp, &profiles);
    own.options.open_machine = .{
        .destination = "box",
    };
    try window_machines.open(gui);
    const slot = gui.machines.find(@enumFromInt(7)).?;
    const box = &gui.clients[slot];
    try std.testing.expect(gui.machines.shown(slot) and gui.app == box);

    // Another machine's change rewrites the file; box's profile is still
    // disabled, as it was when the window opened it.
    var gpu = try core.MachineProfile.init(@enumFromInt(8), .{
        .label = "gpu",
        .destination = "dev@gpu",
    });
    gpu.enabled = false;
    try profiles.add(gpu);
    try saveProfiles(session, &home.temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(gui.machines.shown(slot) and gui.app == box);
    try std.testing.expect(box.model.runtime_link.phase != .stopped);

    // Enabling it and then disabling it is a decision about box, so the
    // window follows it.
    profiles = try boxProfile("dev@box", true);
    try saveProfiles(session, &home.temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(gui.machines.shown(slot) and gui.app == box);

    profiles = try boxProfile("dev@box", false);
    try saveProfiles(session, &home.temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(!gui.machines.shown(slot));
    try std.testing.expect(gui.app == own);
    try std.testing.expectEqual(data.RuntimeLink.Phase.stopped, box.model.runtime_link.phase);
}

test "the machine list closes a machine opened by name whose profile is disabled" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const own = window_machines.window(gui);

    var home: ConfigHome = undefined;
    try home.open(own);
    defer home.close();

    var profiles = try boxProfile("dev@box", false);
    try saveProfiles(session, &home.temp, &profiles);
    own.options.open_machine = .{
        .destination = "box",
    };
    try window_machines.open(gui);
    const slot = gui.machines.find(@enumFromInt(7)).?;
    const box = &gui.clients[slot];

    // Shift+Enter on box, the shown machine, writes a profile that was
    // already disabled; the window closes it anyway.
    pick(box, 1);
    try press(box, .{ .key = .{ .code = .enter, .mods = .{ .shift = true } } });
    while (box.model.to_host.pop()) |effect| {
        if (effect == .machine) {
            try window_machines.choose(gui, effect.machine);
        }
    }

    try writeChanges(box);
    try window_machines.reconcile(gui);
    try std.testing.expect(!gui.machines.shown(slot));
    try std.testing.expect(gui.app == own);
}

test "machines.json changes connect, stop, move and remove the window's machines" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    gui.machines.live[Machines.local_slot] = true;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var profiles = try boxProfile("dev@box", true);
    try saveProfiles(session, &temp, &profiles);
    try window_machines.reconcile(gui);
    const slot = gui.machines.find(@enumFromInt(7)).?;
    const box = &gui.clients[slot];
    try std.testing.expect(gui.machines.live[slot] and gui.machines.shown(slot));
    try std.testing.expect(box.connect_pending);
    try std.testing.expectEqual(data.RuntimeLink.Phase.connecting, gui.machines.phase[slot]);

    profiles = try boxProfile("dev@box", false);
    try saveProfiles(session, &temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(!gui.machines.shown(slot));
    try std.testing.expectEqual(data.RuntimeLink.Phase.stopped, gui.machines.phase[slot]);

    // The attempt to dev@box is still running when the machine moves; its
    // result is dropped and the next attempt reaches the new destination.
    profiles = try boxProfile("dev@gpu", true);
    try saveProfiles(session, &temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(box.connect_outdated);
    try runtime_link.finishConnect(box, error.ConnectionRefused);
    var queued: ?client.BackgroundJob = null;
    while (box.to_background.pop()) |job| {
        queued = job;
    }

    try std.testing.expectEqualStrings("dev@gpu", queued.?.runtime_connect.target.remote.destination);
    try std.testing.expectEqual(data.RuntimeLink.Phase.connecting, box.model.runtime_link.phase);

    gui.machines.active = slot;
    gui.app = box;
    profiles = .{};
    try saveProfiles(session, &temp, &profiles);
    try window_machines.reconcile(gui);
    try std.testing.expect(gui.app == window_machines.window(gui));
    try std.testing.expectEqual(@as(?u8, null), gui.machines.find(@enumFromInt(7)));
    try std.testing.expectEqual(data.RuntimeLink.Phase.stopped, box.model.runtime_link.phase);
}

// Runs the machine changes the client queued, as the window's workers would.
fn writeChanges(app: *client.Client) !void {
    while (app.to_background.pop()) |job| {
        if (job == .machine_edit) {
            _ = try app.update(client.job_runner.runBackground(std.testing.io, std.testing.allocator, job));
        }
    }
}

fn press(app: *client.Client, key: client.name_prompts.Input) !void {
    _ = try client.name_prompt.inputPrompt(app, key);
}

fn pick(app: *client.Client, row: u16) void {
    _ = client.name_prompt.beginCommandPalette(&app.model, .machines);
    app.model.name_prompt.select(row);
}

test "the machine list adds, disables, renames and removes machines through machines.json" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const app = gui.app;
    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    gui.machines.live[Machines.local_slot] = true;

    var home: ConfigHome = undefined;
    try home.open(app);
    defer home.close();

    var profiles: core.MachineProfiles = .{};
    try saveProfiles(session, &home.temp, &profiles);

    // The "Add machine" row follows this machine.
    pick(app, 1);
    try press(app, .{ .key = .{ .code = .enter } });
    try press(app, .{ .command = .{ .insert = "box" } });
    try press(app, .{ .key = .{ .code = .enter } });
    try press(app, .{ .command = .{ .insert = "dev@box" } });
    try press(app, .{ .key = .{ .code = .enter } });
    try writeChanges(app);
    try window_machines.reconcile(gui);
    const slot = gui.machines.findLabel("box").?;
    try std.testing.expect(gui.machines.shown(slot) and gui.machines.live[slot]);
    try std.testing.expectEqualStrings("dev@box", gui.machines.destination(slot));

    // Shift+Enter disables it.
    pick(app, 1);
    try press(app, .{ .key = .{ .code = .enter, .mods = .{ .shift = true } } });
    try writeChanges(app);
    try window_machines.reconcile(gui);
    try std.testing.expect(!gui.machines.shown(slot));
    try std.testing.expectEqual(data.RuntimeLink.Phase.stopped, gui.clients[slot].model.runtime_link.phase);

    // Ctrl+R renames it.
    pick(app, 1);
    try press(app, .{ .command = .rename_entry });
    try press(app, .{ .command = .select_all });
    try press(app, .{ .command = .{ .insert = "gpu" } });
    try press(app, .{ .key = .{ .code = .enter } });
    try writeChanges(app);
    try window_machines.reconcile(gui);
    try std.testing.expectEqualStrings("gpu", gui.machines.label(slot));

    // Ctrl+D removes it.
    pick(app, 1);
    try press(app, .{ .command = .remove_entry });
    try writeChanges(app);
    try window_machines.reconcile(gui);
    try std.testing.expectEqual(@as(?u8, null), gui.machines.findLabel("gpu"));
}
