const localsocket = @import("localsocket");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const Session = @import("Session.zig");
const Fixture = @import("ChromeFixture.zig");
const gui_event = @import("../gui_event.zig");
const input_support = @import("input_support.zig");
const GuiAdapter = @import("../GuiAdapter.zig");
const Target = @import("../widgets/interaction/Target.zig");
const BandPlacement = @import("../widgets/BandPlacement.zig").BandPlacement;
const PointerEvent = @import("../input/PointerEvent.zig");
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

test "an unopened machine keeps keyboard and pointer navigation usable without a runtime" {
    const phases = [_]data.RuntimeLink.Phase{ .failed, .connecting, .lost, .stopped };
    for (phases) |phase| {
        var box = try socketPair();
        defer box.channel.deinit(std.testing.io);
        defer box.peer.deinit(std.testing.io);
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.showSidebar(true);
        const gui = fixture.session.gui;
        const slot = try openMachine(fixture.session, &box.channel);
        const remote = &gui.clients[slot];
        const own = gui.app;
        remote.runtime_transport.unbind();
        remote.model.startup.phase = .opening;
        remote.model.runtime_link.phase = .connecting;
        if (phase == .failed) {
            try runtime_link.finishConnect(remote, error.RemoteTelarIncompatible);
            try std.testing.expect(remote.model.runtime_link.setup_repairs);
        } else {
            remote.model.runtime_link.phase = phase;
        }

        _ = try input_support.action(gui, .{ .select_machine_offset = 1 });
        try std.testing.expect(gui.app == remote);
        try input_support.presented(gui, try fixture.session.draw(), true);

        _ = try input_support.action(gui, .machine_picker);
        try std.testing.expect(remote.model.name_prompt.active());
        try std.testing.expectEqual(data.command_palette.Prefix.machines, remote.model.name_prompt.currentConst().?.paletteMode());
        try input_support.accept(gui, .{ .key = .{ .code = .escape } });
        try input_support.pump(gui);
        try std.testing.expect(!remote.model.name_prompt.active());

        try input_support.accept(gui, .{ .text = .{ .bytes = "discarded while disconnected" } });
        try input_support.pump(gui);
        try std.testing.expectEqual(@as(usize, 0), gui.input_queue.len);
        try std.testing.expectEqual(@as(usize, 0), remote.model.to_runtime.len);
        try input_support.presented(gui, try fixture.session.draw(), true);

        const target = try activityTarget(gui, .{ .select_machine = Machines.local_slot });
        try pointAt(gui, .press, target);
        try pointAt(gui, .release, target);
        try std.testing.expect(gui.app == own);
        try std.testing.expectEqual(@as(usize, 0), gui.input_queue.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
    }
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

test "a window whose sidebar folds its machines keeps drawing, and both picker controls open it" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.measure(.{ .width = 1100, .height = 700, .scale = 1 });
    try fixture.showSidebar(true);
    const gui = fixture.session.gui;

    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    for ([_][]const u8{ "build-server-frankfurt", "gpu-cluster-oregon", "staging" }) |label| {
        _ = try gui.machines.add(.{ .label = label, .destination = label }, null);
    }

    // The second frame is the one that reuses the first frame's identities.
    try input_support.presented(gui, try fixture.session.draw(), true);
    try input_support.presented(gui, try fixture.session.draw(), true);

    const segment = try pickerTarget(gui, .primary);
    const fold = try pickerTarget(gui, .machine_fold);
    try std.testing.expect(!segment.id.eql(fold.id));
    try std.testing.expect(segment.focusable and fold.focusable);

    for ([_]Target{ segment, fold }) |target| {
        try pointAt(gui, .move, target);
        try std.testing.expect(gui.chrome.hovered.?.intent == .machine_picker);
        try std.testing.expectEqual(placementOf(gui, target), gui.chrome.hovered_placement);

        try pointAt(gui, .press, target);
        try pointAt(gui, .release, target);
        const prompt = gui.app.model.name_prompt.currentConst().?;
        try std.testing.expectEqual(data.command_palette.Prefix.machines, prompt.paletteMode());
        _ = gui.app.model.name_prompt.apply(.cancel);
        try input_support.presented(gui, try fixture.session.draw(), true);

        try std.testing.expect(gui.widgets.dispatcher.focus(target.id));
        try std.testing.expect(std.meta.eql(target.bounds, gui.widgets.dispatcher.focusedTarget().?.bounds));
    }
}

// The delivered machine picker control the chrome placed at `placement`.
fn pickerTarget(gui: *GuiAdapter, placement: BandPlacement) !Target {
    const registry = gui.widgets.dispatcher.maps.presented();
    var found: ?Target = null;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .intent and target.action.intent == .machine_picker and target.namespace == @intFromEnum(placement)) {
            try std.testing.expect(found == null);
            found = target;
        }
    }

    return found orelse error.MissingMachinePicker;
}

fn placementOf(gui: *GuiAdapter, target: Target) BandPlacement {
    const hit = gui.chrome.presented().band_hits.hitAt(.{ target.bounds.x + 1, target.bounds.y + 1 }).?;
    return hit.placement;
}

fn pointAt(gui: *GuiAdapter, kind: PointerEvent.Kind, target: Target) !void {
    try input_support.accept(gui, .{ .pointer = .{ .kind = kind, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
    try input_support.pump(gui);
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

// Asks the window to set up the failed machine in `slot` as Enter on its
// row does, checks the tab's title, and returns the words the tab runs.
fn setupTab(session: *Session, slot: u8, words: *[6][]const u8, title: []const u8) ![]const []const u8 {
    const gui = session.gui;
    const own = window_machines.window(gui);
    const remote = &gui.clients[slot];
    remote.model.runtime_link.phase = .failed;
    remote.model.runtime_link.setup_repairs = true;
    try std.testing.expect(gui.machines.summarize(slot, &remote.model, std.testing.io));
    try std.testing.expect(gui.machines.needs_setup[slot]);

    while (own.model.to_host.pop()) |_| {}
    try client.machine_picker.choose(own, slot, false);
    const effect = own.model.to_host.pop() orelse return error.TestExpectedSetupRequest;
    try std.testing.expectEqual(data.MachineRequest{ .setup = slot }, effect.machine);

    try window_machines.choose(gui, effect.machine);
    try std.testing.expect(gui.app == own);
    for (0..64) |_| {
        const bytes = try session.sent();
        const message = try core.decodeClient(bytes);
        try client.runtime_io.completeRuntimeSend(own, {});
        session.pending = null;
        if (message != .create_tab) {
            continue;
        }

        try std.testing.expectEqualStrings(title, message.create_tab.label);
        var arguments = message.create_tab.launch.arguments();
        var count: usize = 0;
        while (try arguments.next()) |word| : (count += 1) {
            words[count] = word;
        }

        return words[0..count];
    }

    return error.TestExpectedSetupTab;
}

test "setup from the window asks first, and names a row --remote opened by its destination" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    const long = "developer@a-host-name-longer-than-a-label.example.lan";
    session.gui.machines.update(slot, .{ .label = "a-host-name-longer-than-a-label.", .destination = long });

    var words: [6][]const u8 = undefined;
    const sent = try setupTab(session, slot, &words, "Set up a-host-name-longer-than-a-label.");
    try std.testing.expectEqual(@as(usize, 5), sent.len);
    try std.testing.expectEqualStrings(long, sent[3]);
    try std.testing.expectEqualStrings("--confirm", sent[4]);
}

test "a machine that lacks this telar build is set up in a tab of this machine" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();

    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    session.gui.machines.id[slot] = @enumFromInt(0x3f9c2a00b001);

    // Enter on its row shows this machine and runs setup in a new tab there.
    var words: [6][]const u8 = undefined;
    const sent = try setupTab(session, slot, &words, "Set up box");
    try std.testing.expectEqual(@as(usize, 5), sent.len);
    try std.testing.expect(std.fs.path.isAbsolute(sent[0]));
    try std.testing.expectEqualStrings("machine", sent[1]);
    try std.testing.expectEqualStrings("setup", sent[2]);
    try std.testing.expectEqualStrings("box", sent[3]);
    try std.testing.expectEqualStrings("--confirm", sent[4]);
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

test "global activity draws a hidden task under its coordinator and disables stale navigation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(true);
    const gui = fixture.session.gui;
    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(fixture.session, &box.channel);
    const own = window_machines.window(gui);
    const remote = &gui.clients[slot];
    const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
    _ = try own.model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = key,
        .session_id = .{1} ** 16,
        .location = Session.location,
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }} });
    _ = try remote.model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = key,
        .session_id = .{2} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .pane_index = 1,
        .provider = .codex,
        .status = .blocked,
    }} });
    _ = try remote.model.workspace_list_snapshot.replace(.{
        .revision = 1,
        .entries = &.{},
        .worktrees = &.{.{
            .worktree = @enumFromInt(1),
            .source = @enumFromInt(1),
            .workspace = @enumFromInt(2),
            .branch = "fix",
            .coordinator = .{ .session_id = .{1} ** 16, .pane_id = key.pane_id, .pane_generation = key.pane_generation },
        }},
    });
    remote.model.runtime_link.phase = .connected;
    _ = gui.machines.summarize(slot, &remote.model, std.testing.io);
    try fixture.paint(gui.projection());
    const parent: client.Intent = .{ .focus_machine_agent = .{ .slot = 0, .key = key, .session_id = .{1} ** 16 } };
    const child: client.Intent = .{ .focus_machine_agent = .{ .slot = slot, .key = key, .session_id = .{2} ** 16 } };
    const parent_bounds = fixture.bandTarget(parent).?;
    const child_bounds = fixture.bandTarget(child).?;
    try std.testing.expect(child_bounds.x > parent_bounds.x);
    try std.testing.expect(child_bounds.y > parent_bounds.y);
    try std.testing.expectEqualDeep(child, fixture.clickBand(child_bounds, 0).intent);
    try std.testing.expect(gui.app == own);

    remote.model.runtime_link.phase = .lost;
    _ = gui.machines.summarize(slot, &remote.model, std.testing.io);
    try fixture.paint(gui.projection());
    try std.testing.expectEqual(@as(usize, 2), fixture.chrome.sidebar.activity_len);
    try std.testing.expect(fixture.bandTarget(child) == null);
    try window_machines.openActivity(gui, child);
    try std.testing.expect(gui.app == own);
}

test "hidden ready activity keeps its age advancing without a working agent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(true);
    const gui = fixture.session.gui;
    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(fixture.session, &box.channel);
    const remote = &gui.clients[slot];
    _ = try remote.model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 },
        .session_id = .{2} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .pane_index = 1,
        .provider = .codex,
        .status = .ready,
        .status_age_s = 59,
    }} });
    remote.model.runtime_link.phase = .connected;
    fixture.chrome.now_ns = 10 * std.time.ns_per_s;
    try fixture.paint(gui.projection());
    const delay = fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns);
    try std.testing.expect(delay > 0 and delay <= 1000);
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(gui.projection());
    try std.testing.expectEqual(@as(u32, 60), fixture.chrome.machine_ages[slot].secondsAt(0));
    remote.model.runtime_link.phase = .lost;
    try fixture.paint(gui.projection());
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
}

test "activity navigation waits for a frame and rejects a reused remote session" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    const remote = &gui.clients[slot];
    const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
    _ = try remote.model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = key,
        .session_id = .{1} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }} });
    const target: client.Intent = .{ .focus_machine_agent = .{ .slot = slot, .key = key, .session_id = .{1} ** 16 } };
    remote.model.runtime_link.phase = .connected;
    const token = try session.draw();
    try window_machines.openActivity(gui, target);
    try std.testing.expectEqual(@as(?u8, slot), gui.pending_machine);
    try std.testing.expectEqualDeep(@as(?client.Intent, target), gui.pending_activity);
    try std.testing.expect(gui.app == window_machines.window(gui));
    remote.model.agent_snapshot.items[0].session_id = .{2} ** 16;
    try input_support.presented(gui, token, true);
    try std.testing.expect(gui.pending_activity == null);
    try std.testing.expect(gui.pending_machine == null);
    try std.testing.expect(gui.app == window_machines.window(gui));
}

test "opening remote activity queues the pane attachment only on its owning client" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    const slot = try openMachine(session, &box.channel);
    const remote = &gui.clients[slot];
    const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
    _ = try remote.model.agent_snapshot.replace(.{ .revision = 1, .agents = &.{.{
        .key = key,
        .session_id = .{2} ** 16,
        .location = .{ .workspace = .{ .workspace = @enumFromInt(2) }, .tab_id = @enumFromInt(2) },
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }} });
    remote.model.runtime_link.phase = .connected;
    const own = window_machines.window(gui);
    const own_outbox = own.model.to_runtime.len;
    try window_machines.openActivity(gui, .{ .focus_machine_agent = .{ .slot = slot, .key = key, .session_id = .{2} ** 16 } });
    try std.testing.expect(gui.app == remote);
    try std.testing.expect(gui.pending_activity == null);
    try std.testing.expect(remote.model.to_runtime.len > 0);
    const message = remote.model.to_runtime.items[remote.model.to_runtime.head];
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqual(Session.pane_id, message.open_pane.target.pane);
    try std.testing.expectEqual(own_outbox, own.model.to_runtime.len);
    // The local pane with the same numeric id is still the local focus.
    const local_tab = own.model.tabs.activeSlot().?;
    try std.testing.expectEqual(Session.pane_id, own.model.tabs.layout[local_tab].focused().?);
}

test "delivered local activity cards focus their pane through pointer keyboard and accessibility input" {
    const Activation = enum { pointer, keyboard, accessibility };
    for ([_]Activation{ .pointer, .keyboard, .accessibility }) |activation| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.showSidebar(true);
        try settleActivitySnapshots(fixture.session);
        const gui = fixture.session.gui;
        const app = gui.app;
        _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
        gui.machines.live[Machines.local_slot] = true;
        const second: core.PaneId = @enumFromInt(11);
        try data.pane_split.split(&app.model, app.model.tabs.active, .{
            .existing_pane = Session.pane_id,
            .new_pane = second,
            .location = Session.location,
            .axis = .horizontal,
            .area = app.geometry().area,
        });
        const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
        _ = try app.model.agent_snapshot.replace(.{
            .revision = 1,
            .agents = &.{.{
                .key = key,
                .session_id = .{1} ** 16,
                .location = Session.location,
                .pane_index = 1,
                .provider = .codex,
                .status = .working,
            }},
        });
        try fixture.session.settle();
        try input_support.presented(gui, try fixture.session.draw(), true);
        const target = try activityTarget(gui, .{ .focus_machine_agent = .{
            .slot = Machines.local_slot,
            .key = key,
            .session_id = .{1} ** 16,
        } });
        try std.testing.expectEqual(second, app.model.tabs.layout[app.model.tabs.active].focused().?);
        switch (activation) {
            .pointer => {
                try pointAt(gui, .press, target);
                try pointAt(gui, .release, target);
            },
            .keyboard => {
                try std.testing.expect(gui.widgets.dispatcher.focus(target.id));
                try input_support.accept(gui, .{ .key = .{ .code = .enter } });
                try input_support.pump(gui);
            },
            .accessibility => {
                try input_support.accept(gui, .{ .accessibility = .{
                    .target_id = target.id.target_id,
                    .generation = target.id.generation,
                    .action = .press,
                } });
                try input_support.pump(gui);
            },
        }

        try std.testing.expectEqual(Session.pane_id, app.model.tabs.layout[app.model.tabs.active].focused().?);
        try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
    }
}

test "a delivered remote activity card switches machines and attaches its agent on pointer input" {
    var box = try socketPair();
    defer box.channel.deinit(std.testing.io);
    defer box.peer.deinit(std.testing.io);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(true);
    try settleActivitySnapshots(fixture.session);
    const gui = fixture.session.gui;
    const slot = try openMachine(fixture.session, &box.channel);
    const remote = &gui.clients[slot];
    const own = gui.app;
    const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
    _ = try remote.model.agent_snapshot.replace(.{
        .revision = 1,
        .agents = &.{.{
            .key = key,
            .session_id = .{2} ** 16,
            .location = Session.location,
            .pane_index = 1,
            .provider = .codex,
            .status = .working,
        }},
    });
    try input_support.presented(gui, try fixture.session.draw(), true);
    const target = try activityTarget(gui, .{ .focus_machine_agent = .{
        .slot = slot,
        .key = key,
        .session_id = .{2} ** 16,
    } });
    try pointAt(gui, .press, target);
    try pointAt(gui, .release, target);
    try std.testing.expect(gui.app == remote);
    try std.testing.expect(gui.pending_activity == null);
    const message = remote.model.to_runtime.items[remote.model.to_runtime.head];
    try std.testing.expect(message == .open_pane);
    try std.testing.expectEqual(Session.pane_id, message.open_pane.target.pane);
    try std.testing.expectEqual(Session.pane_id, own.model.tabs.layout[own.model.tabs.active].focused().?);
}

test "a secondary pointer press on a delivered machine activity card opens its agent peek" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(true);
    try settleActivitySnapshots(fixture.session);
    const gui = fixture.session.gui;
    const app = gui.app;
    _ = try gui.machines.add(.{ .label = "laptop" }, Machines.local_slot);
    gui.machines.live[Machines.local_slot] = true;
    const key: data.AgentKey = .{ .pane_id = Session.pane_id, .pane_generation = 1 };
    _ = try app.model.agent_snapshot.replace(.{
        .revision = 1,
        .agents = &.{.{
            .key = key,
            .session_id = .{1} ** 16,
            .location = Session.location,
            .pane_index = 1,
            .provider = .codex,
            .status = .working,
        }},
    });
    try input_support.presented(gui, try fixture.session.draw(), true);
    const target = try activityTarget(gui, .{ .focus_machine_agent = .{
        .slot = Machines.local_slot,
        .key = key,
        .session_id = .{1} ** 16,
    } });
    try input_support.accept(gui, .{ .pointer = .{
        .kind = .press,
        .button = .right,
        .x = target.bounds.x + 1,
        .y = target.bounds.y + 1,
    } });
    try input_support.pump(gui);
    const prompt = app.model.name_prompt.currentConst() orelse return error.MissingAgentPeek;
    try std.testing.expectEqualDeep(key, prompt.target().peek);
    try std.testing.expect(app.model.peek_screen.reading);
    try std.testing.expectEqual(Session.pane_id, app.model.tabs.layout[app.model.tabs.active].focused().?);
}

fn activityTarget(gui: *GuiAdapter, intent: client.Intent) !Target {
    const registry = gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .intent and std.meta.eql(target.action.intent, intent)) {
            return target;
        }
    }

    return error.MissingActivityCard;
}

// Reply to the initial snapshots before exercising navigation, so the
// production handoff guard has no fixture requests left waiting forever.
fn settleActivitySnapshots(session: *Session) !void {
    const app = session.gui.app;
    var buffer: [4096]u8 = undefined;
    for (app.model.request_lifecycle.tracker.entries) |entry| {
        const request = entry orelse continue;
        const bytes = switch (request.continuation) {
            .workspace_snapshot => |workspace| try core.encodeWorkspaceSnapshot(&buffer, .{
                .request_id = request.request_id,
                .workspace = workspace,
                .name = "project",
                .tabs = &.{.{
                    .tab_id = Session.location.tab_id,
                    .position = 0,
                    .pane_count = 1,
                    .label = "",
                }},
            }),
            .tab_snapshot => |location| try core.encodeTabSnapshot(&buffer, .{
                .request_id = request.request_id,
                .location = location,
                .panes = &.{.{ .pane_id = Session.pane_id, .lifecycle = .running, .pane_generation = 1 }},
            }),
            else => return error.UnexpectedBootstrapRequest,
        };
        _ = try client.runtime_messages.handleServerMessage(app, try core.decodeServer(bytes));
    }

    try session.settle();
    try std.testing.expect(app.model.request_lifecycle.tracker.isEmpty());
}
