//! One shared client driven through its event path without threads: a pane
//! frame or a key through `Client.update`, then `flush`, the job queue the
//! adapter drains, and the write completion. As one machine of a window, it
//! also refreshes its row in the window's machine table after each event.
const localsocket = @import("localsocket");
const cellgrid = @import("cellgrid");
const data = @import("model");
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const ClientEventContext = @This();

const Capacity = enum(usize) {
    frame_payload = 64 * 1024,
};

const pane_id: core.PaneId = @enumFromInt(1);
const held_request: core.RequestId = @enumFromInt(1 << 32);
const location: core.TabLocation = .{
    .workspace = .{
        .workspace = @enumFromInt(1),
    },
    .tab_id = @enumFromInt(1),
};
const pane_size: core.TerminalSize = .{
    .cols = 80,
    .rows = 24,
};

gpa: std.mem.Allocator,
io: std.Io,
app: *client.Client,
connection: localsocket.SocketChannel,
peer: localsocket.SocketChannel,
payload: []u8,
message: data.RuntimeMessage = undefined,
frame_id: u64 = 0,
started_jobs: u64 = 0,
machines: client.Machines = .{},
machine_slot: u8 = client.Machines.local_slot,

/// Builds the client in place, attaches one pane and applies its first
/// snapshot, so every measured frame is an incremental one.
/// Example: `var context: ClientEventContext = undefined; try context.init(io, gpa);`
pub fn init(self: *ClientEventContext, io: std.Io, gpa: std.mem.Allocator) !void {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    self.* = .{
        .gpa = gpa,
        .io = io,
        .app = undefined,
        .connection = channel(sockets[0]),
        .peer = channel(sockets[1]),
        .payload = try gpa.alloc(u8, @intFromEnum(Capacity.frame_payload)),
    };
    errdefer gpa.free(self.payload);

    self.app = try gpa.create(client.Client);
    errdefer gpa.destroy(self.app);
    try self.app.init(.{
        .gpa = gpa,
        .io = io,
        .connection = &self.connection,
        .host_size = .{
            .cols = pane_size.cols,
            .rows = pane_size.rows,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },
        .options = .{
            .arguments = &.{},
            .cwd = "/",
            .endpoint = "",
        },
    });
    self.app.graphics = .{
        .context = self,
        .apply_fn = applyGraphics,
        .clear_pane_fn = clearPane,
        .set_pane_visible_fn = setPaneVisible,
        .pane_visible_fn = paneVisible,
        .has_pane_graphics_fn = hasPaneGraphics,
        .ingress_version_fn = ingressVersion,
        .peek_credit_fn = peekCredit,
        .consume_credit_fn = consumeCredit,
    };
    _ = try data.workspace_handoff.arrive(
        &self.app.model,
        .{
            .pane_id = pane_id,
            .location = location,
            .size = pane_size,
        },
    );

    try client.runtime_io.startRuntimeRead(self.app);
    self.drainJobs();
    const cells = try gpa.alloc(cellgrid.Cell, @as(usize, pane_size.cols) * pane_size.rows);
    defer gpa.free(cells);

    @memset(cells, .{});
    try self.receiveFrame(cells, 0);
}

pub fn deinit(self: *ClientEventContext) void {
    self.app.deinit();
    self.gpa.destroy(self.app);
    self.gpa.free(self.payload);
    self.connection.deinit(self.io);
    self.peer.deinit(self.io);
}

/// One incremental frame of one cell, as a shell echo produces.
/// Example: `const applied = try context.frameEvent(iteration);`
pub fn frameEvent(self: *ClientEventContext, iteration: usize) !u64 {
    var cell: [1]cellgrid.Cell = .{.{}};
    cell[0].bytes[0] = 'a' + @as(u8, @intCast(iteration % 26));
    try self.receiveFrame(&cell, iteration % pane_size.cols);
    return self.frame_id;
}

/// One printable key routed to the focused pane.
/// Example: `const routed = try context.keyEvent();`
pub fn keyEvent(self: *ClientEventContext) !u64 {
    const outcome = try client.key_routing.routeKeyInput(
        self.app,
        .{
            .bytes = "x",
        },
    );
    try self.finishEvent();
    return @intFromEnum(outcome.owner);
}

/// Gives the client a row in a window's machine table and a full agent
/// snapshot, every agent working, as a machine with busy agents has.
/// Example: `try context.loadMachine();`
pub fn loadMachine(self: *ClientEventContext) !void {
    _ = try self.machines.add(.{ .label = "laptop" }, client.Machines.local_slot);
    self.machine_slot = try self.machines.add(.{ .label = "box", .destination = "dev@box" }, null);

    var agents: [core.max_agent_snapshot_entries]data.AgentInput = undefined;
    for (&agents, 0..) |*agent, index| {
        agent.* = .{
            .key = .{
                .pane_id = @enumFromInt(index + 1),
                .pane_generation = 1,
            },
            .location = location,
            .pane_index = @intCast(index),
            .provider = .claude,
            .status = .working,
        };
    }

    _ = try data.agent_snapshot.reconcile(&self.app.model, .{
        .revision = 1,
        .agents = &agents,
    });
    self.summarizeMachine();
}

/// One incremental frame as a window delivers it to one of its machines:
/// the frame through the client, then the refresh of the machine's row.
/// Example: `const applied = try context.machineFrameEvent(iteration);`
pub fn machineFrameEvent(self: *ClientEventContext, iteration: usize) !u64 {
    const applied = try self.frameEvent(iteration);
    self.summarizeMachine();
    return applied +% self.machines.revision;
}

// What `window_machines.handle` does after each of a machine's events.
noinline fn summarizeMachine(self: *ClientEventContext) void {
    _ = self.machines.summarize(self.machine_slot, &self.app.model, self.io);
}

/// Leaves one tab snapshot request pending, as a client has while it waits
/// for the runtime's answer.
/// Example: `try context.holdTabSnapshot(); defer context.releaseTabSnapshot();`
pub fn holdTabSnapshot(self: *ClientEventContext) !void {
    try self.app.model.request_lifecycle.tracker.add(
        held_request,
        .{
            .tab_snapshot = location,
        },
    );
}

pub fn releaseTabSnapshot(self: *ClientEventContext) void {
    _ = self.app.model.request_lifecycle.tracker.take(held_request);
}

/// The pending-request query the native adapter makes before every frame.
/// Example: `const busy = context.requestGroupQuery();`
pub fn requestGroupQuery(self: *ClientEventContext) bool {
    return self.app.model.request_lifecycle.tracker.has(.tab_operation);
}

/// One presentation of the active tab, as an adapter prepares it and the
/// host confirms it: projection, geometry and pane commit captured, the
/// flight begun and completed, and the delivered frames retired.
/// Example: `const retired = try context.presentFrame();`
pub fn presentFrame(self: *ClientEventContext) !u64 {
    const model = &self.app.model;
    const projection = client.capture(
        model,
        .{
            .geometry = data.workbench.region(model),
        },
    );
    const observation: client.Observation = .{
        .model = projection.version,
        .presentation_ingress = projection.presentation_ingress,
        .geometry_revision = projection.geometry.revision,
    };
    _ = self.app.presentation.observe(observation);
    const token = try self.app.presentation.begin(.{
        .observation = observation,
        .commit = data.presentation_delivery.capture(model, projection.tab orelse return error.NoActiveTab),
        .geometry = client.Geometry.capture(projection),
    });
    const delivery = self.app.presentation.complete(token, .delivered) orelse return error.PresentationLost;
    const retired = model.commitPresentation(delivery.commit);
    return retired.len;
}

fn channel(handle: std.c.fd_t) localsocket.SocketChannel {
    return .init(.{
        .socket = .{
            .handle = handle,
            .address = .{
                .ip4 = .loopback(0),
            },
        },
    });
}

fn receiveFrame(self: *ClientEventContext, cells: []const cellgrid.Cell, start: usize) !void {
    const base_frame_id = self.frame_id;
    self.frame_id += 1;
    const bytes = try core.encodePaneFrame(
        self.payload,
        .{
            .pane_id = pane_id,
            .frame_id = self.frame_id,
            .base_frame_id = base_frame_id,
            .cols = pane_size.cols,
            .rows = pane_size.rows,
            .scroll = .{
                .total_rows = pane_size.rows,
                .offset = 0,
            },
            .spans = &.{.{
                .start = @intCast(start),
                .cells = cells,
            }},
        },
    );
    try self.message.decodeInto(self.io, bytes);
    if (try self.app.update(.{ .server = &self.message })) |_| {
        return error.ClientExited;
    }

    try self.finishEvent();
}

/// Flushes as the adapter does after every event, starts the queued jobs
/// and completes the write the flush started.
fn finishEvent(self: *ClientEventContext) !void {
    try self.app.flush();
    self.drainJobs();
    while (self.app.model.to_runtime.inFlight()) {
        _ = try self.app.update(.{ .sent = {} });
        try self.app.flush();
        self.drainJobs();
    }
}

fn drainJobs(self: *ClientEventContext) void {
    while (self.app.to_workers.pop()) |job| {
        self.startJob(job);
    }

    std.debug.assert(self.app.to_background.count == 0);
}

/// Stands in for the adapter's inbox, which copies the job into its task.
noinline fn startJob(self: *ClientEventContext, job: client.Job) void {
    var started = job;
    std.mem.doNotOptimizeAway(&started);
    self.started_jobs +%= @intFromEnum(std.meta.activeTag(started));
}

fn applyGraphics(_: *anyopaque, _: data.PaneGraphicsCommand) !void {
    return error.GraphicsUnsupported;
}

fn clearPane(_: *anyopaque, _: core.PaneId) void {}

fn setPaneVisible(_: *anyopaque, _: core.PaneId, _: bool) !void {}

fn paneVisible(_: *anyopaque, _: core.PaneId) bool {
    return true;
}

fn hasPaneGraphics(_: *anyopaque, _: core.PaneId) bool {
    return false;
}

fn ingressVersion(_: *anyopaque) u64 {
    return 0;
}

fn peekCredit(_: *anyopaque) ?client.GraphicsCredit {
    return null;
}

fn consumeCredit(_: *anyopaque, _: client.GraphicsCredit) void {}
