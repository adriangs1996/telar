//! Native adapter fixture using the production controllers and owned outbox.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const GuiClient = @import("../GuiClient.zig");
const host_ports = @import("../host_ports.zig");
const workers = @import("../workers.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Session = @This();

connection: core.SocketChannel,
peer: core.SocketChannel,
gui: *GuiClient,
pending: ?[]const u8 = null,
opened_link: ?data.LinkTarget = null,
link_open_count: usize = 0,
acknowledgements: [128]core.FrameAck = undefined,
ack_count: usize = 0,
input: [4096]u8 = undefined,
input_len: usize = 0,
last_input_pane: ?core.PaneId = null,
resize_count: usize = 0,
agent_prompt_count: usize = 0,
agent_resume_count: usize = 0,
last_resume: ?core.AgentResume = null,
agent_prompt: [4096]u8 = undefined,
agent_prompt_len: usize = 0,
agent_images: core.AgentImages = .{},
agent_request_id: core.RequestId = @enumFromInt(1),
agent_tab_count: usize = 0,
tab_creation_count: usize = 0,
pane_creation_count: usize = 0,
editor_open_count: usize = 0,
last_editor_open: ?core.OwnedEditorOpen = null,
pane_creation_wire: [8192]u8 = undefined,
pane_creation_len: usize = 0,
approval_count: usize = 0,
last_approval: ?core.AgentApproval = null,

pub const pane_id: core.PaneId = @enumFromInt(10);
pub const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };

pub fn init() !*Session {
    const session = try std.testing.allocator.create(Session);
    errdefer std.testing.allocator.destroy(session);
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }

    session.* = .{
        .connection = .init(.{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } }),
        .peer = .init(.{ .socket = .{ .handle = fds[1], .address = .{ .ip4 = .loopback(0) } } }),
        .gui = undefined,
    };
    errdefer session.connection.deinit(std.testing.io);
    errdefer session.peer.deinit(std.testing.io);
    var measurement = Renderer.init(std.testing.allocator);
    defer measurement.deinit();
    const size = try measurement.measure(
        .{
            .width = 180,
            .height = 240,
            .scale = 1,
        },
    );
    session.gui = try GuiClient.init(
        .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .connection = &session.connection,
            .host_size = size,
            .window_width_px = @as(u32, size.cols) * size.cell_width_px,
            .window_height_px = @as(u32, size.rows) * size.cell_height_px,
            .options = .{
                .arguments = &.{
                    "/bin/sh",
                },
                .cwd = "/",
                .endpoint = "",
            },
        },
    );
    errdefer session.gui.deinit();
    _ = try session.gui.renderer.measure(
        .{
            .width = 180,
            .height = 240,
            .scale = 1,
        },
    );
    session.gui.job_hook = .{
        .context = session,
        .start = startJob,
    };
    return session;
}

pub fn deinit(self: *Session) void {
    self.gui.deinit();
    self.connection.deinit(std.testing.io);
    self.peer.deinit(std.testing.io);
    std.testing.allocator.destroy(self);
}

/// Captures runtime sends and link opens; every other job runs on the real inbox.
/// Example: `session.gui.job_hook = .{ .context = session, .start = Session.startJob };`
pub fn startJob(context: *anyopaque, job: client.Job) !void {
    const session: *Session = @ptrCast(@alignCast(context));

    switch (job) {
        .runtime_read => {},
        .runtime_send => |send| {
            std.debug.assert(session.pending == null);
            session.pending = send.bytes;
        },
        .link => |target| {
            session.opened_link = target;
            session.link_open_count += 1;
        },
        else => try workers.start(session.gui, job),
    }
}

/// The runtime write a direct GUI call left, started as the window loop would.
/// Example: `const request = try core.decodeClient(try session.sent());`
pub fn sent(self: *Session) ![]const u8 {
    try self.startJobs();

    return self.pending orelse error.NothingSent;
}

/// Starts the runtime write and every job a direct GUI call queued.
/// Example: `try session.startJobs();`
pub fn startJobs(self: *Session) !void {
    const app = &self.gui.app;

    try app.flush();
    while (app.to_workers.pop()) |job| {
        try startJob(self, job);
    }
}

pub fn settle(self: *Session) !void {
    var count: usize = 0;
    while (true) {
        if (self.pending == null) {
            _ = try self.gui.update();
            if (self.pending == null) {
                break;
            }
        }

        const bytes = self.pending.?;
        if (count == 2048) {
            return error.UnboundedDelivery;
        }

        count += 1;
        switch (try core.decodeClient(bytes)) {
            .frame_ack => |ack| {
                if (self.ack_count == self.acknowledgements.len) {
                    return error.AckCapacityExceeded;
                }

                self.acknowledgements[self.ack_count] = ack;
                self.ack_count += 1;
            },
            .pane_input => |value| {
                self.last_input_pane = value.pane_id;
                if (value.bytes.len > self.input.len - self.input_len) {
                    return error.InputCapacityExceeded;
                }

                @memcpy(self.input[self.input_len..][0..value.bytes.len], value.bytes);
                self.input_len += value.bytes.len;
            },
            .pane_resize => self.resize_count += 1,
            .agent_resume => |value| {
                self.agent_resume_count += 1;
                self.last_resume = value;
            },
            .agent_prompt => |value| {
                self.agent_prompt_count += 1;
                @memcpy(self.agent_prompt[0..value.text.len], value.text);
                self.agent_prompt_len = value.text.len;
                self.agent_images = try core.AgentImages.copy(value.images);
                self.agent_request_id = value.request_id;
            },
            .open_editor => |request| {
                self.editor_open_count += 1;
                self.last_editor_open = try core.OwnedEditorOpen.init(request);
            },
            .create_pane => {
                self.pane_creation_count += 1;
                @memcpy(self.pane_creation_wire[0..bytes.len], bytes);
                self.pane_creation_len = bytes.len;
            },
            .create_tab => |value| {
                self.tab_creation_count += 1;
                self.agent_tab_count += @intFromBool(value.kind == .agent);
            },
            .agent_approval => |value| {
                self.approval_count += 1;
                self.last_approval = value;
            },
            else => {},
        }

        self.pending = null;
        try client.runtime_io.completeRuntimeSend(&self.gui.app, {});
        try self.startJobs();
    }
}

pub fn bootstrap(self: *Session) !void {
    const app = &self.gui.app;
    try app.model.request_lifecycle.tracker.add(
        client.initial_request_id,
        .{
            .initial_open = .{},
        },
    );
    var buffer: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&buffer, .{ .request_id = client.initial_request_id, .pane_id = pane_id, .location = location, .created = true });
    _ = try client.runtime_messages.handleServerMessage(app, try core.decodeServer(opened));
    app.model.startup.phase = .active;
    try self.settle();
}

pub fn receiveFrame(self: *Session, frame_id: u64) !void {
    const pane = self.gui.app.model.panes.find(pane_id).?;
    const count = pane.buffer.cells.len;
    var cells: [256]core.Cell = @splat(.{});
    if (count > cells.len) {
        return error.TestScreenTooLarge;
    }

    cells[0].bytes[0] = if (frame_id == 1) '$' else 'A' + @as(u8, @intCast(frame_id % 26));
    var wire: [8192]u8 = undefined;
    const encoded = try core.encodePaneFrame(&wire, .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .base_frame_id = frame_id - 1,
        .cols = pane.buffer.w,
        .rows = pane.buffer.h,
        .cursor = .{ .visible = true, .x = 1, .y = 0 },
        .scroll = .{ .total_rows = pane.buffer.h, .offset = 0 },
        .input_modes = .{ .bracketed_paste = true },
        .spans = &.{.{ .start = 0, .cells = if (frame_id == 1) cells[0..count] else cells[0..1] }},
    });
    _ = try client.runtime_messages.handleServerMessage(&self.gui.app, try core.decodeServer(encoded));
    @memset(&wire, 0xff);
}

/// Draws through the production entry using the scenario's measured viewport.
/// Example: `const token = try session.draw();`
pub fn draw(self: *Session) !u64 {
    const renderer = &self.gui.renderer;
    return self.gui.draw(
        .{
            .width = renderer.viewport[0],
            .height = renderer.viewport[1],
            .scale = renderer.scale,
        },
    );
}
