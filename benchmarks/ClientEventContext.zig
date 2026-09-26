//! One shared client driven through its event path without threads: a pane
//! frame or a key through `Client.update`, then `flush`, the job queue the
//! adapter drains, and the write completion.
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
    self.message = try data.RuntimeMessage.decode(self.io, bytes);
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
