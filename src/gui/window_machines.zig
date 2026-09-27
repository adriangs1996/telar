//! The machines one window holds (docs/flows/machine-presentation.md). The
//! window's own client, in `Machines.local_slot`, is this machine's and owns
//! the configuration, the bars and the configuration watch. Every enabled
//! saved machine, and the one `--remote` names, gets a client of its own in
//! another slot that shares that configuration. The window presents one
//! machine; the others keep metadata only and never touch the host.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const host_ports = @import("host_ports.zig");
const workers = @import("workers.zig");

const Machines = client.Machines;

/// The window's own client: this machine's, and the configuration owner.
///
/// ```zig
/// const own = window_machines.window(gui);
/// ```
pub fn window(gui: *GuiAdapter) *client.Client {
    return &gui.clients[Machines.local_slot];
}

/// Fills the table with this machine and the saved ones, opens a client for
/// each enabled one and for a `--remote` machine, and shows the latter. The
/// window's own client has already started.
///
/// ```zig
/// try window_machines.open(gui);
/// ```
pub fn open(gui: *GuiAdapter) !void {
    const machines = &gui.machines;
    const own = window(gui);
    var profiles = loadProfiles(gui);

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local_label = client.profile_file.localLabel(&profiles, &hostname_buffer);
    _ = try machines.add(.{ .label = local_label }, Machines.local_slot);
    machines.live[Machines.local_slot] = true;

    for (profiles.slice()) |*profile| {
        _ = machines.find(profile.id) orelse try machines.add(.{
            .id = profile.id,
            .label = profile.label(),
            .destination = profile.destination(),
            .color = profile.color(),
            .enabled = profile.enabled,
        }, null);
    }

    // `--remote` names a saved machine by destination or label, or opens a
    // temporary one that is never written back.
    var requested: ?u8 = null;
    var requested_arguments: []const []const u8 = &.{};
    if (own.options.open_machine) |remote| {
        const slot = machineFor(machines, remote.destination) orelse try machines.add(.{
            .label = remote.destination,
            .destination = remote.destination,
        }, null);
        machines.enabled[slot] = true;
        requested = slot;
        requested_arguments = remote.arguments;
    }

    for (machines.used, machines.enabled, 0..) |used, enabled, index| {
        const slot: u8 = @intCast(index);
        if (!used or !enabled or slot == Machines.local_slot or machines.live[slot]) {
            continue;
        }

        try openClient(gui, slot, if (requested == slot) requested_arguments else &.{});
    }

    if (requested) |slot| {
        try select(gui, slot);
    }
}

/// Presents another machine: the one shown leaves its workspace and the
/// chosen one opens its own. A frame in flight finishes first.
///
/// ```zig
/// try window_machines.select(gui, slot);
/// ```
pub fn select(gui: *GuiAdapter, slot: u8) !void {
    const machines = &gui.machines;
    if (slot == machines.active or !machines.used[slot] or !machines.live[slot]) {
        return;
    }

    if (gui.app.presentation.active != null) {
        gui.pending_machine = slot;
        return;
    }

    gui.pending_machine = null;
    try client.machine_presentation.hide(gui.app);
    gui.forgetMachineView();

    machines.active = slot;
    machines.revision +%= 1;
    gui.app = &gui.clients[slot];
    gui.app.presentation.preparation_invalid = true;
    try client.machine_presentation.show(gui.app);
    gui.app.model.to_host.resume_input = true;
}

/// Delivers one event to the client in `slot`, refreshes its row, finishes
/// leaving a hidden machine's workspace and drops a hidden client's host
/// effects. A machine other than this one that stops sends the window back
/// to this machine instead of closing it.
///
/// ```zig
/// if (try window_machines.handle(gui, slot, message)) |status| return status;
/// ```
pub fn handle(gui: *GuiAdapter, slot: u8, message: client.Message) !?u8 {
    const app = &gui.clients[slot];
    const status = try app.update(message);
    _ = gui.machines.summarize(slot, &app.model);
    try client.machine_presentation.settle(app);

    if (slot != gui.machines.active) {
        dropHostEffects(app);
        return null;
    }

    if (status) |value| {
        if (slot == Machines.local_slot) {
            return value;
        }

        try select(gui, Machines.local_slot);
        return null;
    }

    return null;
}

/// Writes every live client's queue and starts its jobs. The window's own
/// client uses the plain event; the others tag theirs with their slot.
///
/// ```zig
/// try window_machines.startJobs(gui);
/// ```
pub fn startJobs(gui: *GuiAdapter) !void {
    for (gui.machines.live, 0..) |live, index| {
        if (!live or index == Machines.local_slot) {
            continue;
        }

        const slot: u8 = @intCast(index);
        const app = &gui.clients[slot];
        try app.flush();
        while (true) {
            if (app.to_workers.pop()) |job| {
                workers.startFor(gui, slot, job) catch |err| {
                    try app.failJob(job, err);
                    try app.flush();
                };
            } else if (app.to_background.pop()) |job| {
                workers.startBackgroundFor(gui, slot, job) catch |err| {
                    try app.failBackgroundJob(job, err);
                    try app.flush();
                };
            } else {
                break;
            }
        }
    }
}

/// Gives every other live client the host facts the window's own client
/// just adopted, so a machine shows at the right size when it is chosen.
///
/// ```zig
/// try window_machines.shareHost(gui);
/// ```
pub fn shareHost(gui: *GuiAdapter) !void {
    const own = window(gui);
    for (gui.machines.live, 0..) |live, index| {
        if (!live or index == Machines.local_slot) {
            continue;
        }

        _ = try client.host_resize.applyHostUpdate(&gui.clients[index], .{
            .size = own.model.host.host_size,
            .capabilities = own.model.host.host_capabilities,
        });
    }
}

/// Makes every other live client take the configuration the window's own
/// client just adopted.
///
/// ```zig
/// try window_machines.shareConfiguration(gui);
/// ```
pub fn shareConfiguration(gui: *GuiAdapter) !void {
    const own = window(gui);
    for (gui.machines.live, 0..) |live, index| {
        if (!live or index == Machines.local_slot) {
            continue;
        }

        try client.config_adoption.followConfiguration(&gui.clients[index], own);
    }
}

/// The client identity one window slot presents on a machine, so the
/// runtime keeps one layout per window and machine.
pub fn machineIdentity(window_identity: core.ClientIdentity, destination: []const u8) core.ClientIdentity {
    const value = std.hash.Wyhash.hash(@intFromEnum(window_identity), destination);
    return @enumFromInt(if (value == 0) 1 else value);
}

fn openClient(gui: *GuiAdapter, slot: u8, arguments: []const []const u8) !void {
    const own = window(gui);
    const machines = &gui.machines;
    const destination = machines.destination(slot);
    const identity = machineIdentity(own.client_identity, destination);

    var options = own.options;
    options.machine = .{ .remote = .{
        .destination = destination,
        .arguments = arguments,
        .window_slot = gui.window_slot,
    } };
    options.open_machine = null;
    options.cwd = "";
    options.arguments = &.{};
    options.lua_generation = null;
    options.plugin_registry = null;
    options.trust_store = null;

    const app = &gui.clients[slot];
    const host = own.model.host;
    try client.Client.init(app, .{
        .gpa = own.gpa,
        .io = own.io,
        .host_size = host.host_size,
        .window_width_px = host.host_capabilities.window_width_px,
        .window_height_px = host.host_capabilities.window_height_px,
        .client_identity = identity,
        .options = options,
    });
    machines.live[slot] = true;

    app.owns_configuration = false;
    app.graphics = host_ports.graphicsRetention(gui);
    app.chrome = host_ports.chrome(gui);
    app.host_input_source = host_ports.hostInput(gui);
    app.presented = false;
    try client.config_adoption.followConfiguration(app, own);
    _ = try client.host_resize.applyHostUpdate(app, .{
        .size = host.host_size,
        .capabilities = host.host_capabilities,
    });

    app.model.startup.phase = .opening;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = identity,
        .terminal_colors = host.host_capabilities.terminal_colors,
    };
    try client.runtime_link.start(app);
}

fn machineFor(machines: *const Machines, name: []const u8) ?u8 {
    for (machines.used, 0..) |used, index| {
        const slot: u8 = @intCast(index);
        if (!used or slot == Machines.local_slot) {
            continue;
        }

        if (std.mem.eql(u8, machines.destination(slot), name) or std.mem.eql(u8, machines.label(slot), name)) {
            return slot;
        }
    }

    return null;
}

// A missing, unreadable or invalid file leaves the window with this
// machine only; `telar machine list` reports what is wrong with it.
fn loadProfiles(gui: *GuiAdapter) core.MachineProfiles {
    const own = window(gui);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = client.profile_file.path(own.options.environ, &path_buffer) catch return .{};
    return client.profile_file.load(own.io, own.gpa, path) catch .{};
}

fn dropHostEffects(app: *client.Client) void {
    const effects = &app.model.to_host;
    while (effects.pop()) |effect| {
        switch (effect) {
            .capture => |request| client.clipboard_capture.completeClipboardCapture(app, .{
                .execution_id = @enumFromInt(request.sequence),
                .result = error.NativeServiceUnavailable,
            }) catch {},
            else => {},
        }
    }

    effects.resume_input = false;
    effects.rebind_input = false;
    effects.pane_input = null;
    _ = effects.takePlacementInvalidation();
}

test "one window slot gets a distinct identity on each machine" {
    const window_identity: core.ClientIdentity = @enumFromInt(42);

    try std.testing.expect(machineIdentity(window_identity, "dev@box") != machineIdentity(window_identity, "dev@gpu"));
    try std.testing.expectEqual(machineIdentity(window_identity, "dev@box"), machineIdentity(window_identity, "dev@box"));
    try std.testing.expect(machineIdentity(window_identity, "dev@box") != window_identity);
}
