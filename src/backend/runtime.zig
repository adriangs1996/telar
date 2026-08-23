//! Long-lived runtime for Telar's current schema.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const blit = @import("blit.zig");
const damage = @import("damage.zig");
const history = @import("history/root.zig");
const pty = @import("pty.zig");
const transport = @import("transport.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const diagnostics = core.diagnostics;
const output_chunk_size = 16 * 1024;
const max_pty_response_bytes = 1024;
const max_pty_responses = 64;
const max_workspaces = 64;
const max_tabs_per_workspace = schema.max_tabs_per_workspace;
const max_panes = schema.max_panes_per_tab;
const max_pending_responses = max_panes * 2;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Runtime-owned KGP budgets. Values may be lowered by future user
/// configuration but never raised past the protocol hard limits shared with
/// clients, so every snapshot remains decodable by every compatible client.
pub const GraphicsLimits = struct {
    pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
    global_bytes: usize = core.graphics.max_image_bytes_global,
    images_per_pane: usize = core.graphics.max_images_per_pane,
    placements_per_pane: usize = core.graphics.max_placements_per_pane,
    payload_bytes: usize = core.graphics.max_encoded_chunk_bytes,
    chunks_per_image: usize = core.graphics.max_chunks_per_image,

    pub fn validate(limits: GraphicsLimits) !void {
        if (limits.pane_bytes < 2 or limits.pane_bytes > core.graphics.max_image_bytes_per_pane or
            limits.global_bytes < limits.pane_bytes or limits.global_bytes > core.graphics.max_image_bytes_global or
            limits.images_per_pane < 2 or limits.images_per_pane > core.graphics.max_images_per_pane or
            limits.placements_per_pane < 2 or limits.placements_per_pane > core.graphics.max_placements_per_pane or
            limits.payload_bytes == 0 or limits.payload_bytes > core.graphics.max_encoded_chunk_bytes or
            limits.chunks_per_image == 0 or limits.chunks_per_image > core.graphics.max_chunks_per_image)
            return error.InvalidGraphicsLimits;
    }
};

pub const ServeOptions = struct {
    graphics: GraphicsLimits = .{},
};

const GraphicsBudget = struct {
    mutex: std.atomic.Mutex = .unlocked,
    limit: usize,
    used: usize = 0,

    fn init(limit: usize) GraphicsBudget {
        return .{ .limit = limit };
    }

    fn lock(budget: *GraphicsBudget) void {
        while (!budget.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn reserve(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) bool {
        budget.lock();
        defer budget.mutex.unlock();
        const pane_next = std.math.add(usize, pane.used, bytes) catch return false;
        const global_next = std.math.add(usize, budget.used, bytes) catch return false;
        if (pane_next > pane.limit or global_next > budget.limit) return false;
        pane.used = pane_next;
        budget.used = global_next;
        return true;
    }

    fn release(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) void {
        budget.lock();
        defer budget.mutex.unlock();
        std.debug.assert(bytes <= pane.used and bytes <= budget.used);
        pane.used -= bytes;
        budget.used -= bytes;
    }

    fn releaseAll(budget: *GraphicsBudget, pane: *PaneMediaAllocator) void {
        budget.lock();
        defer budget.mutex.unlock();
        std.debug.assert(pane.used <= budget.used);
        budget.used -= pane.used;
        pane.used = 0;
    }
};

/// Allocator used by VT stream effects and KGP. Charging allocations before
/// forwarding them to the child allocator makes compressed input, decoded
/// pixels, parser buffers and IPC transfer snapshots obey one hard budget.
const PaneMediaAllocator = struct {
    child: std.mem.Allocator,
    budget: *GraphicsBudget,
    limit: usize,
    used: usize = 0,

    fn init(child: std.mem.Allocator, budget: *GraphicsBudget, limit: usize) PaneMediaAllocator {
        return .{ .child = child, .budget = budget, .limit = limit };
    }

    fn allocator(media: *PaneMediaAllocator) std.mem.Allocator {
        return .{ .ptr = media, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn reserveManual(media: *PaneMediaAllocator, bytes: usize) bool {
        return media.budget.reserve(media, bytes);
    }

    fn releaseManual(media: *PaneMediaAllocator, bytes: usize) void {
        media.budget.release(media, bytes);
    }

    fn detach(media: *PaneMediaAllocator) void {
        media.budget.releaseAll(media);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
        if (!media.reserveManual(len)) return null;
        return media.child.rawAlloc(len, alignment, ret_addr) orelse {
            media.releaseManual(len);
            return null;
        };
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and !media.reserveManual(new_len - memory.len)) return false;
        if (!media.child.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) media.releaseManual(new_len - memory.len);
            return false;
        }
        if (new_len < memory.len) media.releaseManual(memory.len - new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and !media.reserveManual(new_len - memory.len)) return null;
        const result = media.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) media.releaseManual(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) media.releaseManual(memory.len - new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
        media.child.rawFree(memory, alignment, ret_addr);
        media.releaseManual(memory.len);
    }
};

const PaneOutputEvent = struct {
    pane: *Pane,
    result: anyerror!u16,
};

const PaneIngestStats = struct {
    elapsed_ns: u64 = 0,
    history_input_bytes: u64 = 0,
    history_captured: u64 = 0,
    history_dropped: u64 = 0,
};

const PaneIngestEvent = struct {
    pane: *Pane,
    result: anyerror!PaneIngestStats,
};

const PaneInputEvent = struct {
    started_ns: u64,
    result: anyerror!void,
};

const PaneExitEvent = struct {
    pane: *Pane,
    result: anyerror!pty.Exit,
};

const PaneResponseEvent = struct {
    pane: *Pane,
    result: anyerror!void,
};

const RuntimeEvent = union(enum) {
    accepted: anyerror!core.transport.SocketChannel,
    client_message: anyerror![]u8,
    client_sent: anyerror!void,
    control_message: anyerror![]u8,
    control_sent: anyerror!void,
    history_response: anyerror!history.Response,
    pane_input_written: PaneInputEvent,
    pane_response_written: PaneResponseEvent,
    pane_output: PaneOutputEvent,
    pane_ingested: PaneIngestEvent,
    pane_exit: PaneExitEvent,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    stopped: anyerror!void,
};

const PtyResponseQueue = struct {
    mutex: std.atomic.Mutex = .unlocked,
    bytes: [max_pty_responses][max_pty_response_bytes]u8 = undefined,
    lengths: [max_pty_responses]u16 = @splat(0),
    head: u8 = 0,
    len: u8 = 0,
    dropped: u64 = 0,

    fn lock(queue: *PtyResponseQueue) void {
        while (!queue.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn push(queue: *PtyResponseQueue, response: []const u8) bool {
        queue.lock();
        defer queue.mutex.unlock();
        if (response.len > max_pty_response_bytes or queue.len == max_pty_responses) {
            queue.dropped += 1;
            return false;
        }
        const index = (@as(usize, queue.head) + queue.len) % max_pty_responses;
        @memcpy(queue.bytes[index][0..response.len], response);
        queue.lengths[index] = @intCast(response.len);
        queue.len += 1;
        return true;
    }

    fn peek(queue_const: *const PtyResponseQueue) ?[]const u8 {
        const queue: *PtyResponseQueue = @constCast(queue_const);
        queue.lock();
        defer queue.mutex.unlock();
        if (queue.len == 0) return null;
        return queue.bytes[queue.head][0..queue.lengths[queue.head]];
    }

    fn pop(queue: *PtyResponseQueue) void {
        queue.lock();
        defer queue.mutex.unlock();
        std.debug.assert(queue.len != 0);
        queue.lengths[queue.head] = 0;
        queue.head = @intCast((@as(usize, queue.head) + 1) % max_pty_responses);
        queue.len -= 1;
    }

    fn clear(queue: *PtyResponseQueue) void {
        queue.lock();
        defer queue.mutex.unlock();
        queue.lengths = @splat(0);
        queue.head = 0;
        queue.len = 0;
    }
};

/// Counts complete Kitty APC commands across arbitrary PTY read boundaries
/// without retaining their payload. Ghostty performs the actual parsing; this
/// tiny recognizer exists only to enforce a bounded number of chunks in an
/// incomplete upload.
const KittyFramingCounter = struct {
    state: State = .normal,

    const State = enum { normal, escape, apc_identify, kitty, kitty_escape, other, other_escape };

    fn observe(counter: *KittyFramingCounter, bytes: []const u8) usize {
        var complete: usize = 0;
        for (bytes) |byte| switch (counter.state) {
            .normal => counter.state = switch (byte) {
                0x1b => .escape,
                0x9f => .apc_identify,
                else => .normal,
            },
            .escape => counter.state = switch (byte) {
                '_' => .apc_identify,
                0x1b => .escape,
                else => .normal,
            },
            .apc_identify => counter.state = if (byte == 'G')
                .kitty
            else if (byte == 0x9c)
                .normal
            else
                .other,
            .kitty => counter.state = switch (byte) {
                0x1b => .kitty_escape,
                0x9c => state: {
                    complete += 1;
                    break :state .normal;
                },
                else => .kitty,
            },
            .kitty_escape => counter.state = if (byte == '\\') state: {
                complete += 1;
                break :state .normal;
            } else if (byte == 0x1b)
                .kitty_escape
            else
                .kitty,
            .other => counter.state = switch (byte) {
                0x1b => .other_escape,
                0x9c => .normal,
                else => .other,
            },
            .other_escape => counter.state = if (byte == '\\')
                .normal
            else if (byte == 0x1b)
                .other_escape
            else
                .other,
        };
        return complete;
    }
};

const HistoryInputBatch = struct {
    const max_entries = 256;
    const Entry = struct {
        offset: u32,
        len: u32,
        shell_foreground: bool,
        clock: history.Clock,
    };

    bytes: [schema.max_input_bytes]u8 = undefined,
    len: usize = 0,
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,

    fn reset(batch: *HistoryInputBatch) void {
        batch.len = 0;
        batch.entry_count = 0;
        batch.cwd_len = 0;
    }

    fn push(
        batch: *HistoryInputBatch,
        bytes: []const u8,
        shell_foreground: bool,
        clock: history.Clock,
        cwd: ?[]const u8,
    ) bool {
        if (batch.entry_count == batch.entries.len or bytes.len > batch.bytes.len - batch.len)
            return false;
        const offset = batch.len;
        @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
        batch.len += bytes.len;
        batch.entries[batch.entry_count] = .{
            .offset = @intCast(offset),
            .len = @intCast(bytes.len),
            .shell_foreground = shell_foreground,
            .clock = clock,
        };
        batch.entry_count += 1;
        if (cwd) |value| {
            batch.cwd_len = @min(value.len, batch.cwd.len);
            @memcpy(batch.cwd[0..batch.cwd_len], value[0..batch.cwd_len]);
        }
        return true;
    }
};

const RuntimeMetrics = struct {
    started_ns: u64,
    client_messages: u64 = 0,
    input_events: u64 = 0,
    input_bytes: u64 = 0,
    input_write: diagnostics.Timing = .{},
    pty_events: u64 = 0,
    pty_bytes: u64 = 0,
    frames: u64 = 0,
    frame_bytes: u64 = 0,
    frame_cells: u64 = 0,
    frame_spans: u64 = 0,
    snapshots: u64 = 0,
    cursor_only_frames: u64 = 0,
    noop_frames: u64 = 0,
    damaged_rows: u64 = 0,
    diff_scanned_cells: u64 = 0,
    coalesced_spans: u64 = 0,
    bridged_cells: u64 = 0,
    coalesced_bytes_saved: u64 = 0,
    folded_pty_events: u64 = 0,
    graphics_messages: u64 = 0,
    graphics_bytes: u64 = 0,
    decode: diagnostics.Timing = .{},
    ingest: diagnostics.Timing = .{},
    encode: diagnostics.Timing = .{},
    ack: diagnostics.Timing = .{},
    history_captured: u64 = 0,
    history_dropped: u64 = 0,
    history_candidate_input_bytes: u64 = 0,
    history_queries: u64 = 0,
    history_query_failures: u64 = 0,
};

const PendingFailure = struct {
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
};

const PendingTabSnapshot = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
};

const PendingWorkspaceSnapshot = struct {
    request_id: schema.RequestId,
    workspace: schema.WorkspaceLocation,
};

const PendingTabCreated = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    position: u16,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,
    root_pane_id: schema.PaneId,

    fn labelSlice(created: *const PendingTabCreated) []const u8 {
        return created.label[0..created.label_len];
    }
};

const PendingTabRenamed = struct {
    request_id: schema.RequestId,
    location: schema.TabLocation,
    label: [schema.max_tab_label_bytes]u8,
    label_len: u8,

    fn labelSlice(renamed: *const PendingTabRenamed) []const u8 {
        return renamed.label[0..renamed.label_len];
    }
};

const PendingResponse = union(enum) {
    pane_opened: schema.PaneOpened,
    request_failed: PendingFailure,
    tab_snapshot: PendingTabSnapshot,
    workspace_snapshot: PendingWorkspaceSnapshot,
    tab_created: PendingTabCreated,
    tab_renamed: PendingTabRenamed,
    tab_closed: schema.TabClosed,
    tab_moved: schema.TabMoved,
    history_result: *history.model.QueryResult,
};

const ResponseQueue = struct {
    items: [max_pending_responses]PendingResponse = undefined,
    head: u8 = 0,
    len: u8 = 0,

    fn push(queue: *ResponseQueue, response: PendingResponse) !void {
        if (queue.len == queue.items.len) return error.ResponseQueueFull;
        const index = (@as(usize, queue.head) + queue.len) % queue.items.len;
        queue.items[index] = response;
        queue.len += 1;
    }

    fn peek(queue: *ResponseQueue) ?*PendingResponse {
        if (queue.len == 0) return null;
        return &queue.items[queue.head];
    }

    fn pop(queue: *ResponseQueue) void {
        std.debug.assert(queue.len != 0);
        queue.head = @intCast((@as(usize, queue.head) + 1) % queue.items.len);
        queue.len -= 1;
    }

    fn clear(queue: *ResponseQueue) void {
        while (queue.peek()) |response| {
            switch (response.*) {
                .history_result => |result| result.deinit(),
                else => {},
            }
            queue.pop();
        }
        queue.head = 0;
    }
};

const ShutdownState = struct {
    requested: bool = false,
    primary_request: bool = false,
    reply_pending: bool = false,
    reply_in_flight: bool = false,
};

const ControlSend = enum {
    none,
    stop,
    history,
};

const OwnedCommand = struct {
    command: pty.Command,
    arguments: []const [:0]u8,
    cwd: [:0]u8,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, launch: schema.LaunchView) !OwnedCommand {
        if (launch.environment_mode != .inherit_runtime or launch.environment_count != 0)
            return error.UnsupportedEnvironment;

        const arguments = try gpa.alloc([:0]u8, launch.argument_count);
        errdefer gpa.free(arguments);
        var initialized: usize = 0;
        errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);

        var iterator = launch.arguments();
        while (try iterator.next()) |argument| {
            arguments[initialized] = try gpa.dupeZ(u8, argument);
            initialized += 1;
        }
        const cwd = try gpa.dupeZ(u8, launch.cwd);
        errdefer gpa.free(cwd);

        var command: pty.Command = .{ .file = arguments[0].ptr, .cwd = cwd.ptr };
        for (arguments, 0..) |argument, index| command.argv[index] = argument.ptr;
        return .{ .command = command, .arguments = arguments, .cwd = cwd, .gpa = gpa };
    }

    fn deinit(command: *OwnedCommand) void {
        for (command.arguments) |argument| command.gpa.free(argument);
        command.gpa.free(command.arguments);
        command.gpa.free(command.cwd);
    }
};

const Pane = struct {
    id: schema.PaneId,
    location: schema.TabLocation,
    session: pty.Session,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    pty_responses: PtyResponseQueue = .{},
    kitty_framing: KittyFramingCounter = .{},
    kitty_loading_chunks: usize = 0,
    graphics_limits: GraphicsLimits,
    graphics_storage_limit: usize,
    media_allocator: PaneMediaAllocator,
    pty_write_mutex: Io.Mutex = .init,
    response_pending: bool = false,
    size: schema.TerminalSize,
    render_state: vt.RenderState = .empty,
    screen: core.ui.Buffer,
    damaged_rows: []bool,
    output_buffer: [output_chunk_size]u8 = undefined,
    cursor: schema.frame.Cursor = .{},
    mouse: schema.frame.Mouse = .{},
    foreground_override: ?vt.color.RGB = null,
    background_override: ?vt.color.RGB = null,
    semantic_colors_dirty: bool = false,
    graphics_revision: u64 = 0,
    graphics_present: bool = false,
    dirty: bool = true,
    output_pending: bool = false,
    ingest_pending: bool = false,
    output_done: bool = false,
    wait_pending: bool = false,
    close_requested: bool = false,
    exit: ?pty.Exit = null,
    history_service: *history.Service,
    history_tracker: history.Tracker,
    history_session_id: history.SessionId,
    history_sequence: u64 = 0,
    history_session_started: bool = false,
    history_session_finished: bool = false,
    workspace_path: []u8,
    history_input_batches: [2]HistoryInputBatch = .{ .{}, .{} },
    history_input_active: u1 = 0,
    history_input_worker: ?u1 = null,
    history_input_dropped: u64 = 0,
    pending_size: ?schema.TerminalSize = null,
    io: Io,
    gpa: std.mem.Allocator,

    fn create(
        io: Io,
        gpa: std.mem.Allocator,
        id: schema.PaneId,
        location: schema.TabLocation,
        command: *const pty.Command,
        workspace_path: []const u8,
        history_service: *history.Service,
        size: schema.TerminalSize,
        graphics_limits: GraphicsLimits,
        graphics_budget: *GraphicsBudget,
    ) !*Pane {
        const pane = try gpa.create(Pane);
        errdefer gpa.destroy(pane);

        pane.id = id;
        pane.location = location;
        pane.io = io;
        pane.gpa = gpa;
        pane.history_service = history_service;
        pane.graphics_limits = graphics_limits;
        pane.graphics_storage_limit = graphics_limits.pane_bytes / 3;
        pane.media_allocator = .init(gpa, graphics_budget, graphics_limits.pane_bytes);
        pane.pty_write_mutex = .init;
        pane.history_session_id = history_service.newSessionId(io);
        pane.history_sequence = 0;
        pane.history_session_started = false;
        pane.history_session_finished = false;
        pane.workspace_path = try gpa.dupe(u8, workspace_path);
        errdefer gpa.free(pane.workspace_path);
        pane.session = try .spawn(command, .{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        });
        errdefer pane.session.deinit();
        pane.size = size;
        pane.terminal = try .init(io, gpa, .{
            .cols = size.cols,
            .rows = size.rows,
            .kitty_image_storage_limit = @min(
                core.graphics.max_image_bytes_per_screen,
                graphics_limits.pane_bytes / 3,
            ),
            .kitty_image_loading_limits = .direct,
        });
        errdefer pane.terminal.deinit(gpa);
        var handler = pane.terminal.vtHandler();
        handler.apc_handler.max_bytes.put(
            .kitty,
            graphics_limits.payload_bytes,
        );
        handler.effects.write_pty = Pane.writePty;
        handler.effects.size = Pane.reportSize;
        pane.stream = vt.TerminalStream.init(.{
            .allocator = pane.media_allocator.allocator(),
            .handler = handler,
        });
        errdefer pane.stream.deinit();
        try pane.stream.handler.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
                .width = size.cell_width_px,
                .height = size.cell_height_px,
            } else null,
        });
        pane.history_tracker = try .init(gpa, workspace_path, &pane.terminal);
        errdefer pane.history_tracker.deinit(&pane.terminal);
        pane.render_state = .empty;
        pane.screen = try .init(gpa, size.cols, size.rows);
        errdefer pane.screen.deinit();
        pane.damaged_rows = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(pane.damaged_rows);
        @memset(pane.damaged_rows, false);
        pane.cursor = .{};
        pane.mouse = .{};
        pane.pty_responses = .{};
        pane.kitty_framing = .{};
        pane.kitty_loading_chunks = 0;
        pane.response_pending = false;
        pane.foreground_override = pane.terminal.colors.foreground.override;
        pane.background_override = pane.terminal.colors.background.override;
        pane.semantic_colors_dirty = false;
        pane.graphics_revision = 0;
        pane.graphics_present = false;
        pane.dirty = true;
        pane.mouse = pane.mouseState();
        pane.output_pending = false;
        pane.ingest_pending = false;
        pane.output_done = false;
        pane.wait_pending = false;
        pane.close_requested = false;
        pane.exit = null;
        pane.history_input_batches = .{ .{}, .{} };
        pane.history_input_active = 0;
        pane.history_input_worker = null;
        pane.history_input_dropped = 0;
        pane.pending_size = null;
        try pane.render(true);
        pane.history_session_started = history_service.startSession(
            io,
            pane.history_session_id,
            pane.id,
            pane.location,
            pane.workspace_path,
            std.mem.span(command.file),
            Io.Timestamp.now(io, .real).toMilliseconds(),
        );
        return pane;
    }

    fn mouseState(pane: *const Pane) schema.frame.Mouse {
        const modes = &pane.terminal.modes;
        const tracking: schema.frame.MouseTracking = if (modes.get(.mouse_event_any))
            .any
        else if (modes.get(.mouse_event_button))
            .button
        else if (modes.get(.mouse_event_normal))
            .normal
        else if (modes.get(.mouse_event_x10))
            .x10
        else
            .none;
        const pixels = modes.get(.mouse_format_sgr_pixels);
        return .{
            .tracking = tracking,
            .sgr = modes.get(.mouse_format_sgr) or pixels,
            .pixels = pixels,
        };
    }

    fn destroy(pane: *Pane) void {
        const gpa = pane.gpa;
        pane.finishHistory();
        gpa.free(pane.workspace_path);
        gpa.free(pane.damaged_rows);
        pane.screen.deinit();
        pane.render_state.deinit(gpa);
        pane.history_tracker.deinit(&pane.terminal);
        pane.stream.deinit();
        pane.media_allocator.detach();
        pane.terminal.deinit(gpa);
        pane.session.deinit();
        gpa.destroy(pane);
    }

    fn ingest(pane: *Pane, io: Io, bytes: []const u8, stats: *PaneIngestStats) !u64 {
        const started = diagnostics.now(io);
        var capture_context: CaptureContext = .{ .pane = pane, .ingest_stats = stats };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = bytes[offset..];
            const boundary = pane.history_tracker.commitBoundary(remaining);
            const slice = if (boundary) |len| remaining[0..len] else remaining;
            const loading_id = if (pane.terminal.screens.active.kitty_images.loading) |loading|
                loading.image.id
            else
                null;
            const kitty_commands = pane.kitty_framing.observe(slice);
            pane.stream.nextSlice(slice);
            pane.enforceIncompleteGraphics(io, loading_id, kitty_commands);
            pane.observeGraphicsDamage();
            if (boundary != null)
                _ = try pane.history_tracker.captureSubmitted(&pane.terminal);
            pane.history_tracker.observeOutput(
                slice,
                historyClock(io),
                pane.session.shellForeground(),
                &capture_context,
                captureCommand,
            );
            offset += slice.len;
        }
        const foreground = pane.terminal.colors.foreground.override;
        const background = pane.terminal.colors.background.override;
        pane.mouse = pane.mouseState();
        if (!std.meta.eql(pane.foreground_override, foreground) or
            !std.meta.eql(pane.background_override, background))
        {
            pane.foreground_override = foreground;
            pane.background_override = background;
            pane.semantic_colors_dirty = true;
        }
        pane.dirty = true;
        pane.graphics_present = pane.terminal.screens.active.kitty_images.images.count() != 0;
        return diagnostics.elapsed(started, diagnostics.now(io));
    }

    fn queueHistoryInput(
        pane: *Pane,
        bytes: []const u8,
        shell_foreground: bool,
        clock: history.Clock,
        cwd: ?[]const u8,
    ) void {
        const batch = &pane.history_input_batches[pane.history_input_active];
        if (!batch.push(bytes, shell_foreground, clock, cwd))
            pane.history_input_dropped +|= 1;
    }

    fn sealHistoryInput(pane: *Pane) void {
        std.debug.assert(pane.history_input_worker == null);
        const sealed = pane.history_input_active;
        pane.history_input_active ^= 1;
        std.debug.assert(pane.history_input_batches[pane.history_input_active].entry_count == 0);
        pane.history_input_worker = sealed;
    }

    fn processHistoryInput(pane: *Pane, stats: *PaneIngestStats) u64 {
        const index = pane.history_input_worker orelse return 0;
        const batch = &pane.history_input_batches[index];
        if (batch.cwd_len != 0)
            pane.history_tracker.updateCwd(batch.cwd[0..batch.cwd_len]);
        var observed: u64 = 0;
        var capture_context: CaptureContext = .{ .pane = pane, .ingest_stats = stats };
        for (batch.entries[0..batch.entry_count]) |entry| {
            const start: usize = entry.offset;
            observed += pane.history_tracker.observeInput(
                &pane.terminal,
                batch.bytes[start..][0..entry.len],
                entry.shell_foreground,
                entry.clock,
                &capture_context,
                captureCommand,
            );
        }
        batch.reset();
        pane.history_input_worker = null;
        return observed;
    }

    fn enforceIncompleteGraphics(
        pane: *Pane,
        io: Io,
        previous_loading_id: ?u32,
        completed_commands: usize,
    ) void {
        const storage = &pane.terminal.screens.active.kitty_images;
        if (previous_loading_id != null or storage.loading != null)
            pane.kitty_loading_chunks +|= completed_commands
        else
            pane.kitty_loading_chunks = 0;

        const chunk_limit_exceeded = pane.kitty_loading_chunks > pane.graphics_limits.chunks_per_image;
        const loading = storage.loading orelse {
            if (chunk_limit_exceeded) if (previous_loading_id) |image_id| {
                storage.delete(io, pane.media_allocator.allocator(), &pane.terminal, .{ .id = .{
                    .delete = true,
                    .image_id = image_id,
                } });
                pane.queueGraphicsLimitResponse(image_id);
            };
            pane.kitty_loading_chunks = 0;
            return;
        };
        if (!chunk_limit_exceeded and
            loading.data.items.len <= pane.graphics_storage_limit) return;

        const image_id = loading.image.id;
        loading.destroy(pane.media_allocator.allocator());
        storage.loading = null;
        pane.kitty_loading_chunks = 0;
        pane.queueGraphicsLimitResponse(image_id);
    }

    fn queueGraphicsLimitResponse(pane: *Pane, image_id: u32) void {
        var response: [128]u8 = undefined;
        const bytes = std.fmt.bufPrint(
            &response,
            "\x1b_Gi={d};ENOMEM: graphics upload limit exceeded\x1b\\",
            .{image_id},
        ) catch return;
        _ = pane.pty_responses.push(bytes);
    }

    fn observeGraphicsDamage(pane: *Pane) void {
        const storage = &pane.terminal.screens.active.kitty_images;
        if (!storage.dirty) return;
        pane.graphics_revision +%= 1;
        if (pane.graphics_revision == 0) pane.graphics_revision = 1;
        storage.dirty = false;
    }

    fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const pane: *Pane = @fieldParentPtr("stream", stream);
        _ = pane.pty_responses.push(response);
    }

    fn reportSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const pane: *Pane = @fieldParentPtr("stream", stream);
        if (pane.size.cell_width_px == 0 or pane.size.cell_height_px == 0) return null;
        return .{
            .rows = pane.size.rows,
            .columns = pane.size.cols,
            .cell_width = pane.size.cell_width_px,
            .cell_height = pane.size.cell_height_px,
        };
    }

    const CaptureContext = struct {
        pane: *Pane,
        metrics: ?*RuntimeMetrics = null,
        ingest_stats: ?*PaneIngestStats = null,
    };

    fn captureCommand(context: *CaptureContext, command: history.Command) void {
        const pane = context.pane;
        if (!pane.history_session_started) return;
        pane.history_sequence += 1;
        const submitted = pane.history_service.recordCommand(pane.io, .{
            .session_id = pane.history_session_id,
            .pane_id = pane.id,
            .location = pane.location,
            .sequence = pane.history_sequence,
            .workspace_path = pane.workspace_path,
            .cols = pane.screen.w,
            .rows = pane.screen.h,
        }, command);
        if (comptime diagnostics.enabled) if (context.metrics) |metrics| {
            if (submitted) metrics.history_captured += 1 else metrics.history_dropped += 1;
        };
        if (comptime diagnostics.enabled) if (context.ingest_stats) |stats| {
            if (submitted) stats.history_captured += 1 else stats.history_dropped += 1;
        };
    }

    fn finishHistory(pane: *Pane) void {
        if (pane.history_session_finished) return;
        var capture_context: CaptureContext = .{ .pane = pane };
        pane.history_tracker.interrupt(historyClock(pane.io), &capture_context, captureCommand);
        if (pane.history_session_started) {
            _ = pane.history_service.finishSession(
                pane.io,
                pane.history_session_id,
                Io.Timestamp.now(pane.io, .real).toMilliseconds(),
            );
        }
        pane.history_session_finished = true;
    }

    fn finishExitedHistory(pane: *Pane, exit: pty.Exit, metrics: *RuntimeMetrics) void {
        var capture_context: CaptureContext = .{ .pane = pane, .metrics = metrics };
        pane.history_tracker.shellExited(
            historyClock(pane.io),
            exit.code(),
            &capture_context,
            captureCommand,
        );
    }

    fn resize(pane: *Pane, size: schema.TerminalSize) !void {
        try pane.requestResize(size);
        try pane.applyPendingResize();
    }

    fn requestResize(pane: *Pane, size: schema.TerminalSize) !void {
        if (std.meta.eql(pane.pending_size orelse pane.size, size)) return;
        try pane.session.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        });
        pane.pending_size = size;
    }

    fn applyPendingResize(pane: *Pane) !void {
        const size = pane.pending_size orelse return;
        pane.pending_size = null;
        try pane.stream.handler.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
                .width = size.cell_width_px,
                .height = size.cell_height_px,
            } else null,
        });
        pane.size = size;
        pane.observeGraphicsDamage();
        try pane.screen.resize(size.cols, size.rows);
        pane.damaged_rows = try pane.gpa.realloc(pane.damaged_rows, size.rows);
        @memset(pane.damaged_rows, false);
        try pane.render(true);
    }

    fn render(pane: *Pane, force: bool) !void {
        try pane.render_state.update(pane.gpa, &pane.terminal);
        const force_all = force or pane.semantic_colors_dirty;
        _ = blit.blit(
            &pane.screen,
            pane.screen.area(),
            &pane.terminal,
            &pane.render_state,
            .{ .force = force_all, .damaged_rows = pane.damaged_rows },
        );
        pane.semantic_colors_dirty = false;
        const cursor = pane.render_state.cursor;
        pane.cursor = if (cursor.visible and cursor.viewport != null and
            cursor.viewport.?.x < pane.screen.w and cursor.viewport.?.y < pane.screen.h)
            .{ .visible = true, .x = cursor.viewport.?.x, .y = cursor.viewport.?.y }
        else
            .{};
        pane.dirty = true;
    }
};

/// Per-client rendering state. It is disposable: reconnecting creates a fresh
/// baseline while the pane and its PTY continue to exist.
const Attachment = struct {
    const KnownImage = struct { key: core.graphics.ImageKey };
    const KnownPlacement = struct { placement: core.graphics.Placement };
    const Transfer = struct {
        metadata: core.graphics.Image,
        pixels: []u8,
        placements: [core.graphics.max_placements_per_pane]core.graphics.Placement = undefined,
        placement_count: usize = 0,
        placement_index: usize = 0,
        offset: usize = 0,
        metadata_sent: bool = false,
    };
    const SnapshotState = enum { begin_pending, open, idle };

    pane: *Pane,
    acknowledged: core.ui.Buffer,
    acknowledged_cursor: schema.frame.Cursor = .{},
    acknowledged_mouse: schema.frame.Mouse = .{},
    next_frame_id: u64 = 1,
    acknowledged_frame_id: u64 = 0,
    outstanding_frame_id: u64 = 0,
    frame_sent_ns: u64 = 0,
    snapshot_pending: bool = true,
    exit_sent: bool = false,
    graphics_snapshot: SnapshotState = .begin_pending,
    graphics_revision: u64 = 1,
    graphics_target_revision: u64 = 0,
    graphics_batch_active: bool = false,
    observed_graphics_revision: u64 = 0,
    transfer: ?Transfer = null,
    known_images: [core.graphics.max_images_per_pane]?KnownImage =
        [_]?KnownImage{null} ** core.graphics.max_images_per_pane,
    known_placements: [core.graphics.max_placements_per_pane]?KnownPlacement =
        [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
        return .{
            .pane = pane,
            .acknowledged = try .init(gpa, pane.screen.w, pane.screen.h),
            .gpa = gpa,
            .graphics_snapshot = if (!pane.graphics_present)
                .idle
            else
                .begin_pending,
            .observed_graphics_revision = if (!pane.graphics_present)
                pane.graphics_revision
            else
                0,
        };
    }

    fn deinit(attachment: *Attachment) void {
        attachment.freeTransfer();
        attachment.acknowledged.deinit();
    }

    fn resizeIfNeeded(attachment: *Attachment) !bool {
        if (attachment.acknowledged.w == attachment.pane.screen.w and
            attachment.acknowledged.h == attachment.pane.screen.h)
        {
            return false;
        }
        try attachment.acknowledged.resize(
            attachment.pane.screen.w,
            attachment.pane.screen.h,
        );
        attachment.outstanding_frame_id = 0;
        attachment.snapshot_pending = true;
        return true;
    }

    fn resetGraphics(attachment: *Attachment) void {
        attachment.freeTransfer();
        attachment.graphics_snapshot = .begin_pending;
        attachment.graphics_batch_active = false;
        attachment.graphics_target_revision = 0;
        attachment.observed_graphics_revision = 0;
        attachment.transfer = null;
        attachment.known_images = [_]?KnownImage{null} ** core.graphics.max_images_per_pane;
        attachment.known_placements = [_]?KnownPlacement{null} ** core.graphics.max_placements_per_pane;
    }

    fn freeTransfer(attachment: *Attachment) void {
        if (attachment.transfer) |transfer| {
            attachment.gpa.free(transfer.pixels);
            attachment.pane.media_allocator.releaseManual(transfer.pixels.len);
        }
        attachment.transfer = null;
    }
};

const Tab = struct {
    id: schema.TabId,
    label: [schema.max_tab_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    fn init(id: schema.TabId, label: []const u8) Tab {
        var tab: Tab = .{ .id = id };
        tab.setLabel(label);
        return tab;
    }

    fn setLabel(tab: *Tab, label: []const u8) void {
        std.debug.assert(label.len != 0 and label.len <= tab.label.len);
        @memcpy(tab.label[0..label.len], label);
        tab.label_len = @intCast(label.len);
    }

    fn labelSlice(tab: *const Tab) []const u8 {
        return tab.label[0..tab.label_len];
    }
};

const Workspace = struct {
    id: schema.WorkspaceId,
    path: []u8,
    tabs: [max_tabs_per_workspace]?Tab = [_]?Tab{null} ** max_tabs_per_workspace,
    tab_count: usize = 0,

    fn defaultTab(workspace: *const Workspace) schema.TabId {
        std.debug.assert(workspace.tab_count != 0);
        return workspace.tabs[0].?.id;
    }

    fn containsTab(workspace: *const Workspace, tab_id: schema.TabId) bool {
        for (workspace.tabs) |candidate|
            if (candidate != null and candidate.?.id == tab_id) return true;
        return false;
    }

    fn findTab(workspace: *Workspace, tab_id: schema.TabId) ?*Tab {
        for (&workspace.tabs) |*slot| {
            const tab = if (slot.*) |*value| value else continue;
            if (tab.id == tab_id) return tab;
        }
        return null;
    }

    fn tabIndex(workspace: *const Workspace, tab_id: schema.TabId) ?usize {
        for (workspace.tabs[0..workspace.tab_count], 0..) |slot, index|
            if (slot != null and slot.?.id == tab_id) return index;
        return null;
    }

    fn appendTab(workspace: *Workspace, tab: Tab) !u16 {
        if (workspace.tab_count == workspace.tabs.len) return error.TabLimitReached;
        const index = workspace.tab_count;
        workspace.tabs[index] = tab;
        workspace.tab_count += 1;
        return @intCast(index);
    }

    fn removeTab(workspace: *Workspace, tab_id: schema.TabId) bool {
        const index = workspace.tabIndex(tab_id) orelse return false;
        var cursor = index;
        while (cursor + 1 < workspace.tab_count) : (cursor += 1)
            workspace.tabs[cursor] = workspace.tabs[cursor + 1];
        workspace.tab_count -= 1;
        workspace.tabs[workspace.tab_count] = null;
        return true;
    }

    fn moveTab(
        workspace: *Workspace,
        tab_id: schema.TabId,
        direction: schema.TabMoveDirection,
    ) ?u16 {
        const index = workspace.tabIndex(tab_id) orelse return null;
        const target = switch (direction) {
            .previous => if (index == 0) index else index - 1,
            .next => if (index + 1 == workspace.tab_count) index else index + 1,
        };
        if (target != index) std.mem.swap(?Tab, &workspace.tabs[index], &workspace.tabs[target]);
        return @intCast(target);
    }
};

const WorkspaceStore = struct {
    const Ensured = struct {
        location: schema.TabLocation,
        created: bool,
    };

    gpa: std.mem.Allocator,
    items: [max_workspaces]?Workspace = [_]?Workspace{null} ** max_workspaces,
    count: usize = 0,
    next_id: u64 = 1,
    next_tab_id: u64 = 1,

    fn init(gpa: std.mem.Allocator) WorkspaceStore {
        return .{ .gpa = gpa };
    }

    fn deinit(store: *WorkspaceStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |workspace| store.gpa.free(workspace.path);
            slot.* = null;
        }
    }

    fn ensure(store: *WorkspaceStore, path: []const u8) !Ensured {
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (std.mem.eql(u8, workspace.path, path))
                return .{
                    .location = .{
                        .workspace = .{ .workspace = workspace.id },
                        .tab_id = workspace.defaultTab(),
                    },
                    .created = false,
                };
        }
        if (store.count == max_workspaces) return error.WorkspaceLimitReached;
        const path_copy = try store.gpa.dupe(u8, path);
        errdefer store.gpa.free(path_copy);
        const workspace_id = try schema.id.workspace(store.next_id);
        store.next_id += 1;
        const tab_id = try schema.id.tab(store.next_tab_id);
        store.next_tab_id += 1;
        for (&store.items) |*slot| {
            if (slot.* == null) {
                var workspace: Workspace = .{ .id = workspace_id, .path = path_copy };
                _ = try workspace.appendTab(.init(tab_id, "main"));
                slot.* = workspace;
                store.count += 1;
                return .{
                    .location = .{
                        .workspace = .{ .workspace = workspace_id },
                        .tab_id = tab_id,
                    },
                    .created = true,
                };
            }
        }
        unreachable;
    }

    fn contains(store: *const WorkspaceStore, location: schema.TabLocation) bool {
        const workspace_id = switch (location.workspace) {
            .workspace => |id| id,
            .worktree => return false,
        };
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (workspace.id == workspace_id)
                return workspace.containsTab(location.tab_id);
        }
        return false;
    }

    fn find(store: *WorkspaceStore, location: schema.WorkspaceLocation) ?*Workspace {
        const workspace_id = switch (location) {
            .workspace => |id| id,
            .worktree => return null,
        };
        for (&store.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            if (workspace.id == workspace_id) return workspace;
        }
        return null;
    }

    fn findTab(store: *WorkspaceStore, location: schema.TabLocation) ?*Tab {
        const workspace = store.find(location.workspace) orelse return null;
        return workspace.findTab(location.tab_id);
    }

    fn createTab(
        store: *WorkspaceStore,
        workspace_location: schema.WorkspaceLocation,
        requested_label: []const u8,
        label_buffer: *[schema.max_tab_label_bytes]u8,
    ) !struct { location: schema.TabLocation, position: u16 } {
        const workspace = store.find(workspace_location) orelse return error.WorkspaceNotFound;
        const tab_id = try schema.id.tab(store.next_tab_id);
        var generated: []const u8 = requested_label;
        if (generated.len == 0) {
            generated = try std.fmt.bufPrint(label_buffer, "tab {d}", .{schema.id.raw(tab_id)});
        }
        const position = try workspace.appendTab(.init(tab_id, generated));
        store.next_tab_id += 1;
        return .{
            .location = .{ .workspace = workspace_location, .tab_id = tab_id },
            .position = position,
        };
    }

    fn removeTab(store: *WorkspaceStore, location: schema.TabLocation) ?bool {
        const workspace = store.find(location.workspace) orelse return null;
        if (!workspace.removeTab(location.tab_id)) return null;
        const workspace_closed = workspace.tab_count == 0;
        if (workspace_closed) {
            const workspace_id = switch (location.workspace) {
                .workspace => |id| id,
                .worktree => unreachable,
            };
            store.remove(workspace_id);
        }
        return workspace_closed;
    }

    fn totalTabs(store: *const WorkspaceStore) usize {
        var count: usize = 0;
        for (store.items) |slot| {
            const workspace = slot orelse continue;
            count += workspace.tab_count;
        }
        return count;
    }

    fn descriptors(
        store: *WorkspaceStore,
        workspace_location: schema.WorkspaceLocation,
        panes: *const PaneStore,
        output: *[max_tabs_per_workspace]schema.TabDescriptor,
    ) ?[]const schema.TabDescriptor {
        const workspace = store.find(workspace_location) orelse return null;
        for (workspace.tabs[0..workspace.tab_count], 0..) |*slot, index| {
            const tab = &slot.*.?;
            const location: schema.TabLocation = .{
                .workspace = workspace_location,
                .tab_id = tab.id,
            };
            output[index] = .{
                .tab_id = tab.id,
                .position = @intCast(index),
                .pane_count = panes.countAt(location),
                .label = tab.labelSlice(),
            };
        }
        return output[0..workspace.tab_count];
    }

    fn remove(store: *WorkspaceStore, workspace_id: schema.WorkspaceId) void {
        for (&store.items) |*slot| {
            const workspace = slot.* orelse continue;
            if (workspace.id == workspace_id) {
                store.gpa.free(workspace.path);
                slot.* = null;
                store.count -= 1;
                return;
            }
        }
        unreachable;
    }
};

const PaneStore = struct {
    items: [max_panes]?*Pane = [_]?*Pane{null} ** max_panes,
    count: usize = 0,
    next_id: u64 = 1,
    graphics_limits: GraphicsLimits = .{},
    graphics_budget: GraphicsBudget = .init(core.graphics.max_image_bytes_global),

    fn find(store: *PaneStore, pane_id: schema.PaneId) ?*Pane {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    fn firstAt(store: *PaneStore, location: schema.TabLocation) ?*Pane {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.close_requested and pane.exit == null and
                std.meta.eql(pane.location, location)) return pane;
        }
        return null;
    }

    fn descriptorsAt(
        store: *const PaneStore,
        location: schema.TabLocation,
        output: *[max_panes]schema.PaneDescriptor,
    ) []const schema.PaneDescriptor {
        var len: usize = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (pane.close_requested or pane.exit != null or
                !std.meta.eql(pane.location, location)) continue;
            output[len] = .{
                .pane_id = pane.id,
                .lifecycle = .running,
            };
            len += 1;
        }
        return output[0..len];
    }

    fn countAt(store: *const PaneStore, location: schema.TabLocation) u16 {
        var count: u16 = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.close_requested and pane.exit == null and
                std.meta.eql(pane.location, location)) count += 1;
        }
        return count;
    }

    fn hasAt(store: *const PaneStore, location: schema.TabLocation) bool {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (std.meta.eql(pane.location, location)) return true;
        }
        return false;
    }

    fn closeAt(store: *PaneStore, location: schema.TabLocation) void {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!std.meta.eql(pane.location, location) or pane.close_requested) continue;
            pane.close_requested = true;
            pane.session.shutdown();
        }
    }

    fn allocateId(store: *PaneStore) !schema.PaneId {
        if (store.count == max_panes) return error.PaneLimitReached;
        const pane_id = try schema.id.pane(store.next_id);
        store.next_id += 1;
        return pane_id;
    }

    fn insert(store: *PaneStore, pane: *Pane) !void {
        for (&store.items) |*slot| {
            if (slot.* == null) {
                slot.* = pane;
                store.count += 1;
                return;
            }
        }
        return error.PaneLimitReached;
    }

    fn removeAndDestroy(store: *PaneStore, pane: *Pane) void {
        for (&store.items) |*slot| {
            if (slot.* == pane) {
                slot.* = null;
                store.count -= 1;
                pane.destroy();
                return;
            }
        }
        unreachable;
    }

    fn shutdown(store: *PaneStore) void {
        for (store.items) |slot| if (slot) |pane| pane.session.shutdown();
    }

    fn deinit(store: *PaneStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |pane| pane.destroy();
            slot.* = null;
        }
        store.count = 0;
    }

    fn collectFinished(
        store: *PaneStore,
        attachments: *AttachmentStore,
        workspaces: *WorkspaceStore,
        responses: ?*ResponseQueue,
    ) !void {
        for (&store.items) |*slot| {
            const pane = slot.* orelse continue;
            if (pane.exit == null or !pane.output_done or
                pane.output_pending or pane.ingest_pending or pane.wait_pending or pane.response_pending or
                pane.pty_responses.len != 0) continue;
            if (attachments.find(pane.id) != null) continue;
            const location = pane.location;
            slot.* = null;
            store.count -= 1;
            pane.destroy();
            if (store.hasAt(location) or workspaces.findTab(location) == null) continue;

            const workspace_closed = workspaces.removeTab(location).?;
            if (responses) |queue| {
                if (attachments.observes(location.workspace)) {
                    try queue.push(.{ .tab_closed = .{
                        .request_id = .none,
                        .location = location,
                        .workspace_closed = workspace_closed,
                    } });
                }
            }
        }
    }
};

const AttachmentStore = struct {
    items: [max_panes]?Attachment = [_]?Attachment{null} ** max_panes,
    count: usize = 0,
    next_send: usize = 0,
    workspace: ?schema.WorkspaceLocation = null,

    fn find(store: *AttachmentStore, pane_id: schema.PaneId) ?*Attachment {
        for (&store.items) |*slot| {
            const attachment = if (slot.*) |*value| value else continue;
            if (attachment.pane.id == pane_id) return attachment;
        }
        return null;
    }

    fn attach(
        store: *AttachmentStore,
        gpa: std.mem.Allocator,
        pane: *Pane,
    ) !*Attachment {
        if (store.find(pane.id)) |existing| return existing;
        if (store.workspace) |workspace| {
            if (!std.meta.eql(workspace, pane.location.workspace))
                return error.WorkspaceMismatch;
        }
        if (store.count == max_panes) return error.AttachmentLimitReached;
        for (&store.items) |*slot| {
            if (slot.* == null) {
                slot.* = try Attachment.init(gpa, pane);
                if (store.workspace == null) store.workspace = pane.location.workspace;
                store.count += 1;
                return &slot.*.?;
            }
        }
        unreachable;
    }

    fn detach(store: *AttachmentStore, pane_id: schema.PaneId) bool {
        for (&store.items) |*slot| {
            const attachment = if (slot.*) |*value| value else continue;
            if (attachment.pane.id != pane_id) continue;
            attachment.deinit();
            slot.* = null;
            store.count -= 1;
            return true;
        }
        return false;
    }

    fn observes(store: *const AttachmentStore, workspace: schema.WorkspaceLocation) bool {
        return store.workspace != null and std.meta.eql(store.workspace.?, workspace);
    }

    fn deinit(store: *AttachmentStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |*attachment| attachment.deinit();
            slot.* = null;
        }
        store.count = 0;
        store.next_send = 0;
        store.workspace = null;
    }
};

pub fn serve(io: Io, gpa: std.mem.Allocator, endpoint: []const u8) !void {
    return serveInternal(io, gpa, endpoint, ":memory:", null, null, .{});
}

pub fn serveWithHistory(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
) !void {
    return serveInternal(io, gpa, endpoint, history_path, null, null, .{});
}

pub fn serveWithHistoryOptions(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
    options: ServeOptions,
) !void {
    try options.graphics.validate();
    return serveInternal(io, gpa, endpoint, history_path, null, null, options);
}

/// Test seam for stopping an otherwise long-lived runtime without signals.
pub fn serveUntil(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    stop: *Io.Queue(u8),
) !void {
    return serveInternal(io, gpa, endpoint, ":memory:", stop, null, .{});
}

pub fn serveUntilWithHistory(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
    stop: *Io.Queue(u8),
) !void {
    return serveInternal(io, gpa, endpoint, history_path, stop, null, .{});
}

/// Deterministic integration seam proving that PTY input remains independent
/// while a pane's bounded ingest actor is occupied. Production entry points
/// never install this gate.
pub const IngestTestGate = struct {
    entered: *Io.Queue(u8),
    release: *Io.Queue(u8),
    claimed: std.atomic.Value(bool) = .init(false),

    fn wait(gate: *IngestTestGate, io: Io) !void {
        if (gate.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        try gate.entered.putOne(io, 0);
        _ = try gate.release.getOne(io);
    }
};

pub fn serveUntilWithIngestGate(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    stop: *Io.Queue(u8),
    gate: *IngestTestGate,
) !void {
    return serveInternal(io, gpa, endpoint, ":memory:", stop, gate, .{});
}

fn serveInternal(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
    stop: ?*Io.Queue(u8),
    ingest_gate: ?*IngestTestGate,
    options: ServeOptions,
) !void {
    try options.graphics.validate();
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("TERM_PROGRAM", "telar", 1);

    var listener = try transport.local.LocalListener.listen(io, endpoint);
    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "runtime-{d}",
        .{std.c.getpid()},
    ) catch "runtime";
    var telemetry = diagnostics.Sink.init(io, endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);
    const input_buffer = try gpa.alloc(u8, schema.max_input_bytes);
    defer gpa.free(input_buffer);
    const control_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(control_buffer);

    var history_service = try history.Service.init(gpa, history_path);
    var history_worker = try io.concurrent(history.runWorker, .{ io, &history_service });
    var history_owned = true;
    errdefer if (history_owned) {
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
    };

    var select_storage: [17 + 4 * max_panes]RuntimeEvent = undefined;
    var select = Io.Select(RuntimeEvent).init(io, &select_storage);
    try select.concurrent(.accepted, acceptClient, .{ io, &listener });
    if (stop) |queue| try select.concurrent(.stopped, waitForStop, .{ io, queue });
    try select.concurrent(.history_response, history.receiveResponse, .{ io, &history_service });
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var connection: ?core.transport.SocketChannel = null;
    var control_connection: ?core.transport.SocketChannel = null;
    var control_send: ControlSend = .none;
    var client_read_pending = false;
    var client_send_pending = false;
    var pane_input_pending = false;
    var attachments: AttachmentStore = .{};
    var responses: ResponseQueue = .{};
    var sent_exit_pane: ?schema.PaneId = null;
    var shutdown: ShutdownState = .{};
    var workspaces = WorkspaceStore.init(gpa);
    var panes: PaneStore = .{
        .graphics_limits = options.graphics,
        .graphics_budget = .init(options.graphics.global_bytes),
    };
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    var metrics: RuntimeMetrics = .{ .started_ns = diagnostics.now(io) };
    defer {
        listener.shutdown();
        if (connection) |*active| active.shutdown(io);
        if (control_connection) |*active| active.shutdown(io);
        // `pane_exit` blocks in libc's waitpid and cannot observe Select
        // cancellation. End the PTY session first so all actors can finish.
        panes.shutdown();
        select.cancelDiscard();
        listener.deinit(io);
        if (connection) |*active| active.deinit(io);
        if (control_connection) |*active| active.deinit(io);
        attachments.deinit();
        panes.deinit();
        workspaces.deinit();
        responses.clear();
        history_service.closeQueues(io);
        _ = history_worker.await(io) catch {};
        history_service.deinit(io);
        history_owned = false;
    }

    while (true) switch (try select.await()) {
        .stopped => |result| return result,
        .accepted => |result| {
            var accepted = result catch {
                try select.concurrent(.accepted, acceptClient, .{ io, &listener });
                continue;
            };
            try select.concurrent(.accepted, acceptClient, .{ io, &listener });
            if (connection != null or pane_input_pending) {
                if (control_connection != null) {
                    accepted.deinit(io);
                    continue;
                }
                control_connection = accepted;
                try select.concurrent(.control_message, receiveClient, .{
                    io,
                    &control_connection.?,
                    control_buffer,
                });
                continue;
            }
            connection = accepted;
            responses.clear();
            dropAttachments(&attachments, &panes, &workspaces);
            sent_exit_pane = null;
            client_read_pending = true;
            try select.concurrent(.client_message, receiveClient, .{
                io,
                &connection.?,
                receive_buffer,
            });
        },
        .client_message => |result| {
            client_read_pending = false;
            const payload = result catch {
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                dropAttachments(&attachments, &panes, &workspaces);
                responses.clear();
                continue;
            };
            const decode_started = diagnostics.now(io);
            const message = schema.decodeClient(payload) catch {
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                dropAttachments(&attachments, &panes, &workspaces);
                continue;
            };
            if (comptime diagnostics.enabled) {
                metrics.client_messages += 1;
                metrics.decode.observe(diagnostics.elapsed(decode_started, diagnostics.now(io)));
            }
            dispatchClientMessage(
                io,
                gpa,
                &select,
                message,
                &panes,
                &workspaces,
                &attachments,
                &responses,
                input_buffer,
                &pane_input_pending,
                &shutdown,
                &metrics,
                &history_service,
            ) catch |err| {
                if (err == error.RuntimeConcurrencyUnavailable) return err;
                if (shutdown.primary_request) return;
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                dropAttachments(&attachments, &panes, &workspaces);
                continue;
            };
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                &attachments,
                &panes,
                &workspaces,
                &responses,
                &client_send_pending,
                &sent_exit_pane,
                &shutdown,
                &metrics,
            ) catch {
                if (shutdown.primary_request) return;
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attachments,
                    &panes,
                    &workspaces,
                );
                continue;
            };
            if (!pane_input_pending and !shutdown.requested) {
                client_read_pending = true;
                try select.concurrent(.client_message, receiveClient, .{
                    io,
                    &connection.?,
                    receive_buffer,
                });
            }
        },
        .client_sent => |result| {
            client_send_pending = false;
            if (shutdown.reply_in_flight) {
                shutdown.reply_in_flight = false;
                _ = result catch {};
                return;
            }
            result catch {
                if (shutdown.primary_request) return;
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attachments,
                    &panes,
                    &workspaces,
                );
                continue;
            };
            if (sent_exit_pane) |pane_id| {
                sent_exit_pane = null;
                _ = attachments.detach(pane_id);
                try panes.collectFinished(&attachments, &workspaces, &responses);
            }
            if (connection == null or !connection.?.isActive()) {
                if (!client_read_pending) connection = null;
                continue;
            }
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                &attachments,
                &panes,
                &workspaces,
                &responses,
                &client_send_pending,
                &sent_exit_pane,
                &shutdown,
                &metrics,
            ) catch {
                if (shutdown.primary_request) return;
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attachments,
                    &panes,
                    &workspaces,
                );
            };
        },
        .control_message => |result| {
            const payload = result catch {
                control_connection.?.deinit(io);
                control_connection = null;
                continue;
            };
            const message = schema.decodeClient(payload) catch {
                control_connection.?.deinit(io);
                control_connection = null;
                continue;
            };
            switch (message) {
                .runtime_stop => {
                    shutdown.requested = true;
                    const reply = try schema.encodeRuntimeStopping(control_buffer);
                    control_send = .stop;
                    select.concurrent(.control_sent, sendClient, .{
                        io,
                        &control_connection.?,
                        reply,
                    }) catch |err| {
                        return err;
                    };
                },
                .query_history => |request| {
                    const query = history.Query.init(
                        request.request_id,
                        .control,
                        request.query,
                        request.scope,
                        request.scope_value,
                        request.pane_id,
                        request.failed_only,
                        request.limit,
                    ) catch {
                        const reply = try schema.encodeRequestFailed(control_buffer, .{
                            .request_id = request.request_id,
                            .code = .invalid_request,
                            .message = "invalid history query",
                        });
                        control_send = .history;
                        try select.concurrent(.control_sent, sendClient, .{
                            io,
                            &control_connection.?,
                            reply,
                        });
                        continue;
                    };
                    if (!history_service.query(io, query)) {
                        if (comptime diagnostics.enabled) metrics.history_query_failures += 1;
                        const reply = try schema.encodeRequestFailed(control_buffer, .{
                            .request_id = request.request_id,
                            .code = .resource_limit,
                            .message = "history queue is full",
                        });
                        control_send = .history;
                        try select.concurrent(.control_sent, sendClient, .{
                            io,
                            &control_connection.?,
                            reply,
                        });
                        continue;
                    }
                    if (comptime diagnostics.enabled) metrics.history_queries += 1;
                },
                else => {
                    control_connection.?.deinit(io);
                    control_connection = null;
                },
            }
        },
        .control_sent => |result| {
            _ = result catch {};
            if (control_send == .history) {
                control_send = .none;
                control_connection.?.deinit(io);
                control_connection = null;
                continue;
            }
            control_send = .none;
            // A control client gets the acknowledgement first. The attached
            // UI then gets an explicit shutdown message so it can leave raw
            // mode cleanly instead of interpreting EOF as a runtime failure.
            shutdown.primary_request = true;
            shutdown.reply_pending = true;
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                &attachments,
                &panes,
                &workspaces,
                &responses,
                &client_send_pending,
                &sent_exit_pane,
                &shutdown,
                &metrics,
            ) catch return;
            if (!client_send_pending) return;
        },
        .history_response => |response_result| {
            const response = response_result catch continue;
            try select.concurrent(.history_response, history.receiveResponse, .{
                io,
                &history_service,
            });
            switch (response) {
                .query_result => |result| switch (result.origin) {
                    .primary => responses.push(.{ .history_result = result }) catch {
                        result.deinit();
                    },
                    .control => {
                        defer result.deinit();
                        if (control_connection == null) continue;
                        var entries: [history.model.max_results]schema.HistoryEntry = undefined;
                        const reply = encodeHistoryResult(control_buffer, result, &entries) catch {
                            control_connection.?.deinit(io);
                            control_connection = null;
                            continue;
                        };
                        control_send = .history;
                        try select.concurrent(.control_sent, sendClient, .{
                            io,
                            &control_connection.?,
                            reply,
                        });
                    },
                },
                .failed => |failure| switch (failure.origin) {
                    .primary => queueFailure(
                        &responses,
                        failure.request_id,
                        .internal,
                        failure.message,
                    ) catch {},
                    .control => {
                        if (control_connection == null) continue;
                        const reply = schema.encodeRequestFailed(control_buffer, .{
                            .request_id = failure.request_id,
                            .code = .internal,
                            .message = failure.message,
                        }) catch {
                            control_connection.?.deinit(io);
                            control_connection = null;
                            continue;
                        };
                        control_send = .history;
                        try select.concurrent(.control_sent, sendClient, .{
                            io,
                            &control_connection.?,
                            reply,
                        });
                    },
                },
            }
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                &attachments,
                &panes,
                &workspaces,
                &responses,
                &client_send_pending,
                &sent_exit_pane,
                &shutdown,
                &metrics,
            ) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attachments, &panes, &workspaces);
            };
        },
        .pane_input_written => |event| {
            pane_input_pending = false;
            if (comptime diagnostics.enabled)
                metrics.input_write.observe(diagnostics.elapsed(event.started_ns, diagnostics.now(io)));
            event.result catch {
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attachments,
                    &panes,
                    &workspaces,
                );
                continue;
            };
            if (connectionPointer(&connection) != null and !client_read_pending) {
                client_read_pending = true;
                try select.concurrent(.client_message, receiveClient, .{
                    io,
                    &connection.?,
                    receive_buffer,
                });
            }
        },
        .pane_response_written => |event| {
            const active = event.pane;
            active.response_pending = false;
            if (event.result) |_| {
                active.pty_responses.pop();
                try schedulePaneResponse(io, &select, active);
            } else |_| {
                active.pty_responses.clear();
            }
            try panes.collectFinished(
                &attachments,
                &workspaces,
                if (connectionPointer(&connection) != null) &responses else null,
            );
        },
        .pane_output => |event| {
            const active = event.pane;
            active.output_pending = false;
            const output_len = event.result catch {
                active.output_done = true;
                if (active.exit) |exit| active.finishExitedHistory(exit, &metrics);
                try panes.collectFinished(
                    &attachments,
                    &workspaces,
                    if (connectionPointer(&connection) != null) &responses else null,
                );
                pumpSend(io, &select, connectionPointer(&connection), send_buffer, &attachments, &panes, &workspaces, &responses, &client_send_pending, &sent_exit_pane, &shutdown, &metrics) catch {
                    closeClient(io, &connection, client_read_pending, client_send_pending, &attachments, &panes, &workspaces);
                };
                continue;
            };
            if (output_len == 0) {
                active.output_done = true;
                if (active.exit) |exit| active.finishExitedHistory(exit, &metrics);
            } else {
                if (comptime diagnostics.enabled) {
                    metrics.pty_events += 1;
                    metrics.pty_bytes += output_len;
                    if (attachments.find(active.id)) |value| {
                        if (value.outstanding_frame_id != 0)
                            metrics.folded_pty_events += 1;
                    }
                }
                active.sealHistoryInput();
                active.ingest_pending = true;
                try select.concurrent(.pane_ingested, ingestPane, .{
                    io,
                    active,
                    output_len,
                    ingest_gate,
                });
                continue;
            }
            try panes.collectFinished(
                &attachments,
                &workspaces,
                if (connectionPointer(&connection) != null) &responses else null,
            );
            pumpSend(io, &select, connectionPointer(&connection), send_buffer, &attachments, &panes, &workspaces, &responses, &client_send_pending, &sent_exit_pane, &shutdown, &metrics) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attachments, &panes, &workspaces);
            };
        },
        .pane_ingested => |event| {
            const active = event.pane;
            active.ingest_pending = false;
            const stats = event.result catch {
                active.close_requested = true;
                active.session.shutdown();
                active.output_done = true;
                try panes.collectFinished(
                    &attachments,
                    &workspaces,
                    if (connectionPointer(&connection) != null) &responses else null,
                );
                continue;
            };
            if (comptime diagnostics.enabled) {
                metrics.ingest.observe(stats.elapsed_ns);
                metrics.history_candidate_input_bytes += stats.history_input_bytes;
                metrics.history_captured += stats.history_captured;
                metrics.history_dropped += stats.history_dropped;
            }
            try active.applyPendingResize();
            if (attachments.find(active.id)) |attachment| _ = try attachment.resizeIfNeeded();
            enforceGraphicsQuotas(io, active);
            active.observeGraphicsDamage();
            try schedulePaneResponse(io, &select, active);
            active.output_pending = true;
            try select.concurrent(.pane_output, readPane, .{ io, active });
            try panes.collectFinished(
                &attachments,
                &workspaces,
                if (connectionPointer(&connection) != null) &responses else null,
            );
            pumpSend(io, &select, connectionPointer(&connection), send_buffer, &attachments, &panes, &workspaces, &responses, &client_send_pending, &sent_exit_pane, &shutdown, &metrics) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attachments, &panes, &workspaces);
            };
        },
        .pane_exit => |event| {
            const active = event.pane;
            active.wait_pending = false;
            active.exit = try event.result;
            if (active.output_done) active.finishExitedHistory(active.exit.?, &metrics);
            try panes.collectFinished(
                &attachments,
                &workspaces,
                if (connectionPointer(&connection) != null) &responses else null,
            );
            pumpSend(io, &select, connectionPointer(&connection), send_buffer, &attachments, &panes, &workspaces, &responses, &client_send_pending, &sent_exit_pane, &shutdown, &metrics) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attachments, &panes, &workspaces);
            };
        },
        .telemetry_tick => |result| {
            result catch {
                telemetry.deinit(io);
                continue;
            };
            if (!telemetry.available()) continue;
            select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io}) catch {
                telemetry.deinit(io);
                continue;
            };
            if (telemetry_write_pending) continue;

            const line = formatRuntimeTelemetry(
                &telemetry_buffer,
                io,
                &metrics,
                &attachments,
                workspaces.count,
                workspaces.totalTabs(),
                &panes,
                &history_service,
            ) catch continue;
            telemetry_write_pending = true;
            select.concurrent(.telemetry_written, writeDiagnostics, .{
                io,
                &telemetry,
                line,
            }) catch {
                telemetry_write_pending = false;
                telemetry.deinit(io);
            };
        },
        .telemetry_written => |result| {
            telemetry_write_pending = false;
            result catch telemetry.deinit(io);
        },
    };
}

fn dispatchClientMessage(
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(RuntimeEvent),
    message: schema.ClientMessage,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    attachments: *AttachmentStore,
    responses: *ResponseQueue,
    input_buffer: []u8,
    input_pending: *bool,
    shutdown: *ShutdownState,
    metrics: *RuntimeMetrics,
    history_service: *history.Service,
) !void {
    switch (message) {
        .open_pane => |open| {
            var created = false;
            const active = switch (open.target) {
                .pane => |wanted| pane: {
                    const existing = panes.find(wanted) orelse {
                        try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                        return;
                    };
                    if (existing.close_requested or existing.exit != null) {
                        try queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                        return;
                    }
                    break :pane existing;
                },
                .default => pane: {
                    const launch = open.launch.?;
                    const ensured = workspaces.ensure(launch.cwd) catch {
                        try queueFailure(responses, open.request_id, .resource_limit, "could not create workspace");
                        return;
                    };
                    var workspace_committed = !ensured.created;
                    const workspace_id = switch (ensured.location.workspace) {
                        .workspace => |id| id,
                        .worktree => unreachable,
                    };
                    defer if (!workspace_committed) workspaces.remove(workspace_id);
                    const location = ensured.location;
                    if (panes.firstAt(location)) |existing| {
                        if (existing.exit != null and existing.output_done) {
                            _ = attachments.detach(existing.id);
                            panes.removeAndDestroy(existing);
                        } else break :pane existing;
                    }
                    const fresh = spawnPane(
                        io,
                        gpa,
                        select,
                        panes,
                        location,
                        open.size,
                        launch,
                        history_service,
                    ) catch |err| {
                        if (err == error.RuntimeConcurrencyUnavailable) return err;
                        try queueSpawnFailure(responses, open.request_id, err);
                        return;
                    };
                    workspace_committed = true;
                    created = true;
                    break :pane fresh;
                },
            };

            if (active.ingest_pending)
                try active.requestResize(open.size)
            else
                try active.resize(open.size);
            const attachment = try attachments.attach(gpa, active);
            _ = try attachment.resizeIfNeeded();
            try responses.push(.{ .pane_opened = .{
                .request_id = open.request_id,
                .pane_id = active.id,
                .location = active.location,
                .created = created,
            } });
        },
        .pane_input => |input| {
            const active = (try attachedPane(attachments, input.pane_id)).pane;
            if (active.exit != null) return;
            if (comptime diagnostics.enabled) {
                metrics.input_events += 1;
                metrics.input_bytes += input.bytes.len;
            }
            var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = active.session.cwd(&cwd_buffer);
            active.queueHistoryInput(
                input.bytes,
                active.session.shellForeground() orelse false,
                historyClock(io),
                cwd,
            );
            std.debug.assert(!input_pending.*);
            @memcpy(input_buffer[0..input.bytes.len], input.bytes);
            input_pending.* = true;
            select.concurrent(.pane_input_written, writePaneInput, .{
                io,
                active,
                input_buffer[0..input.bytes.len],
                if (comptime diagnostics.enabled) diagnostics.now(io) else 0,
            }) catch |err| {
                input_pending.* = false;
                return err;
            };
        },
        .pane_resize => |resize| {
            const active = try attachedPane(attachments, resize.pane_id);
            try active.pane.requestResize(resize.size);
            if (!active.pane.ingest_pending) {
                try active.pane.applyPendingResize();
                _ = try active.resizeIfNeeded();
            }
            // Resizing may cause the emulator to emit an in-band resize
            // report. Treat it like every other terminal-produced response:
            // queue it behind the bounded PTY response writer.
            if (!active.pane.ingest_pending)
                try schedulePaneResponse(io, select, active.pane);
        },
        .request_graphics_snapshot => |request| {
            const active = try attachedPane(attachments, request.pane_id);
            active.resetGraphics();
        },
        .frame_ack => |ack| {
            const active = try attachedPane(attachments, ack.pane_id);
            if (ack.frame_id != active.outstanding_frame_id) return;
            if (comptime diagnostics.enabled) {
                metrics.ack.observe(diagnostics.elapsed(active.frame_sent_ns, diagnostics.now(io)));
            }
            active.acknowledged_frame_id = ack.frame_id;
            active.outstanding_frame_id = 0;
        },
        .request_snapshot => |request| {
            const active = try attachedPane(attachments, request.pane_id);
            active.snapshot_pending = true;
        },
        .detach_pane => |detach| {
            if (!attachments.detach(detach.pane_id)) return error.PaneNotFound;
        },
        .request_tab_snapshot => |request| {
            if (!tabExists(workspaces, request.location)) {
                try queueFailure(responses, request.request_id, .tab_not_found, "tab not found");
                return;
            }
            try responses.push(.{ .tab_snapshot = .{
                .request_id = request.request_id,
                .location = request.location,
            } });
        },
        .create_pane => |create| {
            if (!tabExists(workspaces, create.location)) {
                try queueFailure(responses, create.request_id, .pane_not_found, "tab not found");
                return;
            }
            const fresh = spawnPane(
                io,
                gpa,
                select,
                panes,
                create.location,
                create.size,
                create.launch,
                history_service,
            ) catch |err| {
                if (err == error.RuntimeConcurrencyUnavailable) return err;
                try queueSpawnFailure(responses, create.request_id, err);
                return;
            };
            _ = try attachments.attach(gpa, fresh);
            try responses.push(.{ .pane_opened = .{
                .request_id = create.request_id,
                .pane_id = fresh.id,
                .location = fresh.location,
                .created = true,
            } });
        },
        .close_pane => |close| {
            const active = attachments.find(close.pane_id) orelse {
                try queueFailure(responses, close.request_id, .pane_not_found, "pane not attached");
                return;
            };
            if (!active.pane.close_requested) {
                active.pane.close_requested = true;
                active.pane.session.shutdown();
            }
        },
        .request_workspace_snapshot => |request| {
            if (workspaces.find(request.workspace) == null) {
                try queueFailure(
                    responses,
                    request.request_id,
                    .workspace_not_found,
                    "workspace not found",
                );
                return;
            }
            try responses.push(.{ .workspace_snapshot = .{
                .request_id = request.request_id,
                .workspace = request.workspace,
            } });
        },
        .create_tab => |create| {
            var generated_label: [schema.max_tab_label_bytes]u8 = undefined;
            const created = workspaces.createTab(
                create.workspace,
                create.label,
                &generated_label,
            ) catch |err| {
                switch (err) {
                    error.WorkspaceNotFound => try queueFailure(
                        responses,
                        create.request_id,
                        .workspace_not_found,
                        "workspace not found",
                    ),
                    error.TabLimitReached => try queueFailure(
                        responses,
                        create.request_id,
                        .resource_limit,
                        "tab limit reached",
                    ),
                    else => return err,
                }
                return;
            };
            var tab_committed = false;
            defer if (!tab_committed) {
                _ = workspaces.removeTab(created.location);
            };
            const fresh = spawnPane(
                io,
                gpa,
                select,
                panes,
                created.location,
                create.size,
                create.launch,
                history_service,
            ) catch |err| {
                if (err == error.RuntimeConcurrencyUnavailable) return err;
                try queueSpawnFailure(responses, create.request_id, err);
                return;
            };
            _ = try attachments.attach(gpa, fresh);
            const tab = workspaces.findTab(created.location).?;
            var pending: PendingTabCreated = .{
                .request_id = create.request_id,
                .location = created.location,
                .position = created.position,
                .label = undefined,
                .label_len = @intCast(tab.labelSlice().len),
                .root_pane_id = fresh.id,
            };
            @memcpy(pending.label[0..pending.label_len], tab.labelSlice());
            try responses.push(.{ .tab_created = pending });
            tab_committed = true;
        },
        .rename_tab => |rename| {
            const tab = workspaces.findTab(rename.location) orelse {
                try queueFailure(responses, rename.request_id, .tab_not_found, "tab not found");
                return;
            };
            tab.setLabel(rename.label);
            var pending: PendingTabRenamed = .{
                .request_id = rename.request_id,
                .location = rename.location,
                .label = undefined,
                .label_len = @intCast(rename.label.len),
            };
            @memcpy(pending.label[0..pending.label_len], rename.label);
            try responses.push(.{ .tab_renamed = pending });
        },
        .close_tab => |close| {
            if (!tabExists(workspaces, close.location)) {
                try queueFailure(responses, close.request_id, .tab_not_found, "tab not found");
                return;
            }
            panes.closeAt(close.location);
            const workspace_closed = workspaces.removeTab(close.location).?;
            try responses.push(.{ .tab_closed = .{
                .request_id = close.request_id,
                .location = close.location,
                .workspace_closed = workspace_closed,
            } });
        },
        .move_tab => |move| {
            const workspace = workspaces.find(move.location.workspace) orelse {
                try queueFailure(
                    responses,
                    move.request_id,
                    .workspace_not_found,
                    "workspace not found",
                );
                return;
            };
            const position = workspace.moveTab(move.location.tab_id, move.direction) orelse {
                try queueFailure(responses, move.request_id, .tab_not_found, "tab not found");
                return;
            };
            try responses.push(.{ .tab_moved = .{
                .request_id = move.request_id,
                .location = move.location,
                .position = position,
            } });
        },
        .query_history => |request| {
            const query = history.Query.init(
                request.request_id,
                .primary,
                request.query,
                request.scope,
                request.scope_value,
                request.pane_id,
                request.failed_only,
                request.limit,
            ) catch {
                try queueFailure(
                    responses,
                    request.request_id,
                    .invalid_request,
                    "invalid history query",
                );
                return;
            };
            if (!history_service.query(io, query)) {
                if (comptime diagnostics.enabled) metrics.history_query_failures += 1;
                try queueFailure(
                    responses,
                    request.request_id,
                    .resource_limit,
                    "history queue is full",
                );
                return;
            }
            if (comptime diagnostics.enabled) metrics.history_queries += 1;
        },
        .runtime_stop => {
            shutdown.requested = true;
            shutdown.primary_request = true;
            shutdown.reply_pending = true;
        },
    }
}

fn tabExists(
    workspaces: *const WorkspaceStore,
    location: schema.TabLocation,
) bool {
    return workspaces.contains(location);
}

fn queueFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    code: schema.FailureCode,
    message: []const u8,
) !void {
    try responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = code,
        .message = message,
    } });
}

fn queueSpawnFailure(
    responses: *ResponseQueue,
    request_id: schema.RequestId,
    spawn_error: anyerror,
) !void {
    switch (spawn_error) {
        error.PaneLimitReached => try queueFailure(
            responses,
            request_id,
            .resource_limit,
            "pane limit reached",
        ),
        error.UnsupportedEnvironment => try queueFailure(
            responses,
            request_id,
            .invalid_request,
            "unsupported launch environment",
        ),
        else => try queueFailure(
            responses,
            request_id,
            .spawn_failed,
            "could not start pane process",
        ),
    }
}

fn spawnPane(
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(RuntimeEvent),
    panes: *PaneStore,
    location: schema.TabLocation,
    size: schema.TerminalSize,
    launch: schema.LaunchView,
    history_service: *history.Service,
) !*Pane {
    var command = try OwnedCommand.init(gpa, launch);
    defer command.deinit();
    const pane_id = try panes.allocateId();
    const fresh = fresh: {
        const created = try Pane.create(
            io,
            gpa,
            pane_id,
            location,
            &command.command,
            launch.cwd,
            history_service,
            size,
            panes.graphics_limits,
            &panes.graphics_budget,
        );
        errdefer created.destroy();
        try panes.insert(created);
        break :fresh created;
    };
    select.concurrent(.pane_output, readPane, .{ io, fresh }) catch |err| {
        panes.removeAndDestroy(fresh);
        return err;
    };
    fresh.output_pending = true;
    select.concurrent(.pane_exit, waitPane, .{fresh}) catch {
        // The output actor already owns `fresh`, so this cannot be recovered
        // as a failed request without risking a use-after-free. Stop the
        // runtime; its normal teardown shuts down the PTY, joins the actor and
        // only then destroys the pane.
        fresh.close_requested = true;
        fresh.session.shutdown();
        return error.RuntimeConcurrencyUnavailable;
    };
    fresh.wait_pending = true;
    return fresh;
}

fn enforceGraphicsQuotas(io: Io, pane: *Pane) void {
    // The allocator has already reserved every VT and frozen-transfer byte
    // against the pane and runtime counters. This pass only enforces count
    // limits after a complete ingest. It never touches another pane because
    // that pane may be parsing concurrently in its own actor.
    enforceGraphicsCounts(io, pane, .primary);
    enforceGraphicsCounts(io, pane, .alternate);
}

fn enforceGraphicsCounts(io: Io, pane: *Pane, screen_key: vt.ScreenSet.Key) void {
    const screen = pane.terminal.screens.get(screen_key) orelse return;
    const previous_key = pane.terminal.screens.active_key;
    const previous = pane.terminal.screens.active;
    pane.terminal.screens.active_key = screen_key;
    pane.terminal.screens.active = screen;
    defer {
        pane.terminal.screens.active_key = previous_key;
        pane.terminal.screens.active = previous;
    }
    const storage = &screen.kitty_images;
    const placement_limit = pane.graphics_limits.placements_per_pane / 2;
    if (storage.placements.count() > placement_limit)
        storage.delete(io, pane.media_allocator.allocator(), &pane.terminal, .{ .all = false });

    const image_limit = pane.graphics_limits.images_per_pane / 2;
    while (storage.images.count() > image_limit) {
        var oldest_id: ?u32 = null;
        var oldest_generation: u64 = std.math.maxInt(u64);
        var iterator = storage.images.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.generation >= oldest_generation) continue;
            oldest_generation = entry.value_ptr.generation;
            oldest_id = entry.key_ptr.*;
        }
        storage.delete(io, pane.media_allocator.allocator(), &pane.terminal, .{ .id = .{
            .delete = true,
            .image_id = oldest_id orelse break,
        } });
    }
}

fn encodeFrame(
    io: Io,
    buffer: []u8,
    attachment: *Attachment,
    force_snapshot: bool,
    metrics: *RuntimeMetrics,
) !?[]const u8 {
    const pane = attachment.pane;
    const started = diagnostics.now(io);
    if (pane.dirty) try pane.render(false);
    var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
    var snapshot = force_snapshot;
    const diff = if (snapshot)
        damage.Diff{}
    else
        damage.collectSpans(
            pane.screen.cells,
            attachment.acknowledged.cells,
            pane.screen.w,
            pane.damaged_rows,
            &span_storage,
        );
    var span_count = diff.span_count;
    snapshot = snapshot or diff.snapshot_required;

    const cursor_changed = !std.meta.eql(pane.cursor, attachment.acknowledged_cursor);
    const mouse_changed = !std.meta.eql(pane.mouse, attachment.acknowledged_mouse);
    if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed) {
        @memset(pane.damaged_rows, false);
        pane.dirty = false;
        if (comptime diagnostics.enabled) {
            metrics.noop_frames += 1;
            metrics.damaged_rows += diff.damaged_rows;
            metrics.diff_scanned_cells += diff.scanned_cells;
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
            metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
        }
        return null;
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = pane.screen.cells };
        span_count = 1;
    }

    const frame_id = attachment.next_frame_id;
    attachment.next_frame_id += 1;
    const payload = try schema.encodePaneFrame(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else attachment.acknowledged_frame_id,
        .cols = pane.screen.w,
        .rows = pane.screen.h,
        .cursor = pane.cursor,
        .mouse = pane.mouse,
        .spans = span_storage[0..span_count],
    });
    if (snapshot) {
        @memcpy(attachment.acknowledged.cells, pane.screen.cells);
    } else {
        for (span_storage[0..span_count]) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(attachment.acknowledged.cells[start..][0..span.cells.len], span.cells);
        }
    }
    attachment.acknowledged_cursor = pane.cursor;
    attachment.acknowledged_mouse = pane.mouse;
    attachment.outstanding_frame_id = frame_id;
    attachment.frame_sent_ns = diagnostics.now(io);
    @memset(pane.damaged_rows, false);
    pane.dirty = false;
    if (comptime diagnostics.enabled) {
        var cell_count: u64 = 0;
        for (span_storage[0..span_count]) |span| cell_count += span.cells.len;
        metrics.frames += 1;
        metrics.frame_bytes += payload.len;
        metrics.frame_cells += cell_count;
        metrics.frame_spans += span_count;
        if (snapshot) metrics.snapshots += 1;
        if (!snapshot and span_count == 0) metrics.cursor_only_frames += 1;
        metrics.damaged_rows += diff.damaged_rows;
        metrics.diff_scanned_cells += diff.scanned_cells;
        if (!snapshot) {
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
        }
        metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
    }
    return payload;
}

fn encodeNextGraphics(
    buffer: []u8,
    attachment: *Attachment,
) !?[]const u8 {
    const pane = attachment.pane;
    const storage = &pane.terminal.screens.active.kitty_images;
    if (!attachment.graphics_batch_active) {
        attachment.graphics_target_revision = pane.graphics_revision;
        attachment.graphics_revision = @max(pane.graphics_revision, @as(u64, 1));
        attachment.graphics_batch_active = true;
    }
    const revision = attachment.graphics_revision;

    if (attachment.graphics_snapshot == .begin_pending) {
        attachment.known_images = [_]?Attachment.KnownImage{null} ** core.graphics.max_images_per_pane;
        attachment.known_placements = [_]?Attachment.KnownPlacement{null} ** core.graphics.max_placements_per_pane;
        attachment.freeTransfer();
        attachment.graphics_snapshot = .open;
        return try schema.encodeGraphicsSnapshot(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .phase = .begin,
        });
    }

    if (attachment.transfer) |*transfer| {
        if (!transfer.metadata_sent) {
            transfer.metadata_sent = true;
            return try schema.encodeGraphicsImage(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .image = transfer.metadata,
            });
        }
        if (transfer.offset < transfer.pixels.len) {
            const remaining = transfer.pixels[transfer.offset..];
            const take = @min(remaining.len, core.graphics.max_ipc_chunk_bytes);
            const offset = transfer.offset;
            transfer.offset += take;
            return try schema.encodeGraphicsImageChunk(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .key = transfer.metadata.key,
                .offset = offset,
                .bytes = remaining[0..take],
            });
        }
        try rememberImage(attachment, transfer.metadata.key);
        if (transfer.placement_index < transfer.placement_count) {
            const placement = transfer.placements[transfer.placement_index];
            transfer.placement_index += 1;
            if (knownPlacement(attachment, placement.virtual_id)) |known|
                known.placement = placement
            else
                try rememberPlacement(attachment, placement);
            return try schema.encodeGraphicsPlacement(buffer, .{
                .pane_id = pane.id,
                .revision = revision,
                .placement = placement,
            });
        }
        attachment.freeTransfer();
    }

    // Keep the currently displayed generation until its replacement image and
    // placements have crossed the bounded transport. Exterior IDs include the
    // generation, so both may coexist without aliasing during the handoff.
    for (&attachment.known_images) |*slot| {
        const known = slot.* orelse continue;
        const current = storage.imageById(known.key.image_id);
        if (current != null and current.?.generation == known.key.generation) continue;
        if (current) |replacement| if (!knowsImage(attachment, .{
            .image_id = replacement.id,
            .generation = replacement.generation,
        })) continue;
        slot.* = null;
        forgetPlacementsForImage(attachment, known.key);
        return try schema.encodeGraphicsDeleteImage(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .key = known.key,
        });
    }

    var image_iterator = storage.images.iterator();
    while (image_iterator.next()) |entry| {
        const image = entry.value_ptr;
        if (image.data.bytes() == null) continue;
        const key: core.graphics.ImageKey = .{
            .image_id = image.id,
            .generation = image.generation,
        };
        if (knowsImage(attachment, key)) continue;
        const pixels = image.data.bytes() orelse continue;
        const format: core.graphics.Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            else => return error.UnsupportedGraphicsFormat,
        };
        const metadata: core.graphics.Image = .{
            .key = key,
            .format = format,
            .width = image.width,
            .height = image.height,
            .byte_len = pixels.len,
        };
        _ = try metadata.validate(pane.graphics_storage_limit);
        if (!pane.media_allocator.reserveManual(pixels.len))
            return error.GraphicsQuotaExceeded;
        errdefer pane.media_allocator.releaseManual(pixels.len);
        const frozen = try attachment.gpa.dupe(u8, pixels);
        attachment.transfer = .{ .metadata = metadata, .pixels = frozen };
        var placement_iterator = storage.placements.iterator();
        while (placement_iterator.next()) |placement_entry| {
            if (placement_entry.key_ptr.image_id != image.id) continue;
            const placement = placementValue(
                pane,
                placement_entry.key_ptr.*,
                placement_entry.value_ptr.*,
                image.*,
            ) orelse continue;
            const index = attachment.transfer.?.placement_count;
            if (index == core.graphics.max_placements_per_pane) break;
            attachment.transfer.?.placements[index] = placement;
            attachment.transfer.?.placement_count += 1;
        }
        return encodeNextGraphics(buffer, attachment);
    }

    for (&attachment.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (findPlacement(storage, known.placement.virtual_id) != null) continue;
        slot.* = null;
        return try schema.encodeGraphicsDeletePlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .key = known.placement.key,
            .virtual_id = known.placement.virtual_id,
            .placement_id = known.placement.placement_id,
        });
    }

    var placement_iterator = storage.placements.iterator();
    while (placement_iterator.next()) |entry| {
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        if (!knowsImage(attachment, .{ .image_id = image.id, .generation = image.generation }))
            continue;
        const placement = placementValue(pane, entry.key_ptr.*, entry.value_ptr.*, image) orelse
            continue;
        if (knownPlacement(attachment, placement.virtual_id)) |known| {
            if (std.meta.eql(known.placement, placement)) continue;
            known.placement = placement;
        } else try rememberPlacement(attachment, placement);
        return try schema.encodeGraphicsPlacement(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .placement = placement,
        });
    }

    attachment.observed_graphics_revision = attachment.graphics_target_revision;
    attachment.graphics_batch_active = false;
    if (attachment.graphics_snapshot == .open) {
        attachment.graphics_snapshot = .idle;
        return try schema.encodeGraphicsSnapshot(buffer, .{
            .pane_id = pane.id,
            .revision = revision,
            .phase = .end,
        });
    }
    return null;
}

fn knowsImage(attachment: *const Attachment, key: core.graphics.ImageKey) bool {
    for (attachment.known_images) |slot| if (slot) |known| {
        if (std.meta.eql(known.key, key)) return true;
    };
    return false;
}

fn rememberImage(attachment: *Attachment, key: core.graphics.ImageKey) !void {
    if (knowsImage(attachment, key)) return;
    for (&attachment.known_images) |*slot| if (slot.* == null) {
        slot.* = .{ .key = key };
        return;
    };
    return error.GraphicsImageLimitReached;
}

fn forgetPlacementsForImage(attachment: *Attachment, key: core.graphics.ImageKey) void {
    for (&attachment.known_placements) |*slot| {
        const known = slot.* orelse continue;
        if (std.meta.eql(known.placement.key, key)) slot.* = null;
    }
}

fn knownPlacement(attachment: *Attachment, virtual_id: u64) ?*Attachment.KnownPlacement {
    for (&attachment.known_placements) |*slot| {
        const known = if (slot.*) |*value| value else continue;
        if (known.placement.virtual_id == virtual_id) return known;
    }
    return null;
}

fn rememberPlacement(attachment: *Attachment, placement: core.graphics.Placement) !void {
    for (&attachment.known_placements) |*slot| if (slot.* == null) {
        slot.* = .{ .placement = placement };
        return;
    };
    return error.GraphicsPlacementLimitReached;
}

fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    const tag: u64 = switch (key.placement_id.tag) {
        .internal => 0,
        .external => 1,
    };
    return ((tag << 32) | key.placement_id.id) + 1;
}

fn findPlacement(
    storage: *vt.kitty.graphics.ImageStorage,
    virtual_id: u64,
) ?vt.kitty.graphics.ImageStorage.Placement {
    var iterator = storage.placements.iterator();
    while (iterator.next()) |entry| {
        if (placementVirtualId(entry.key_ptr.*) == virtual_id) return entry.value_ptr.*;
    }
    return null;
}

fn placementValue(
    pane: *Pane,
    key: vt.kitty.graphics.ImageStorage.PlacementKey,
    placement: vt.kitty.graphics.ImageStorage.Placement,
    image: vt.kitty.graphics.Image,
) ?core.graphics.Placement {
    const pin = switch (placement.location) {
        .pin => |value| value,
        .virtual => return null,
    };
    if (pin.garbage) return null;
    const pages = &pane.terminal.screens.active.pages;
    const screen_point = pages.pointFromPin(.screen, pin.*) orelse return null;
    const viewport = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const source = placement.sourceRect(image);
    return .{
        .key = .{ .image_id = image.id, .generation = image.generation },
        .virtual_id = placementVirtualId(key),
        .placement_id = switch (key.placement_id.tag) {
            .internal => 0,
            .external => key.placement_id.id,
        },
        .x = @intCast(screen_point.screen.x),
        .y = @as(i32, @intCast(screen_point.screen.y)) -
            @as(i32, @intCast(viewport.screen.y)),
        .source_x = source.x,
        .source_y = source.y,
        .source_width = source.width,
        .source_height = source.height,
        .columns = placement.columns,
        .rows = placement.rows,
        .offset_x = placement.x_offset,
        .offset_y = placement.y_offset,
        .z_index = placement.z,
    };
}

fn pumpSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    connection: ?*core.transport.SocketChannel,
    buffer: []u8,
    attachments: *AttachmentStore,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    responses: *ResponseQueue,
    send_pending: *bool,
    sent_exit_pane: *?schema.PaneId,
    shutdown: *ShutdownState,
    metrics: *RuntimeMetrics,
) !void {
    if (connection == null or send_pending.*) return;

    if (shutdown.reply_pending) {
        const payload = try schema.encodeRuntimeStopping(buffer);
        shutdown.reply_pending = false;
        shutdown.reply_in_flight = true;
        startSend(io, select, connection.?, payload, send_pending) catch |err| {
            shutdown.reply_in_flight = false;
            return err;
        };
        return;
    }

    if (responses.peek()) |response| {
        var descriptor_storage: [max_panes]schema.PaneDescriptor = undefined;
        var tab_storage: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
        var history_storage: [history.model.max_results]schema.HistoryEntry = undefined;
        var history_result: ?*history.model.QueryResult = null;
        const payload = switch (response.*) {
            .request_failed => |failure| try schema.encodeRequestFailed(buffer, .{
                .request_id = failure.request_id,
                .code = failure.code,
                .message = failure.message,
            }),
            .pane_opened => |opened| try schema.encodePaneOpened(buffer, opened),
            .tab_snapshot => |snapshot| try schema.encodeTabSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .location = snapshot.location,
                .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
            }),
            .workspace_snapshot => |snapshot| try schema.encodeWorkspaceSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .tabs = workspaces.descriptors(snapshot.workspace, panes, &tab_storage) orelse
                    return error.WorkspaceNotFound,
            }),
            .tab_created => |*created| try schema.encodeTabCreated(buffer, .{
                .request_id = created.request_id,
                .location = created.location,
                .position = created.position,
                .label = created.labelSlice(),
                .root_pane_id = created.root_pane_id,
            }),
            .tab_renamed => |*renamed| try schema.encodeTabRenamed(buffer, .{
                .request_id = renamed.request_id,
                .location = renamed.location,
                .label = renamed.labelSlice(),
            }),
            .tab_closed => |closed| try schema.encodeTabClosed(buffer, closed),
            .tab_moved => |moved| try schema.encodeTabMoved(buffer, moved),
            .history_result => |result| payload: {
                history_result = result;
                break :payload try encodeHistoryResult(buffer, result, &history_storage);
            },
        };
        try startSend(io, select, connection.?, payload, send_pending);
        if (history_result) |result| result.deinit();
        responses.pop();
        return;
    }

    var checked: usize = 0;
    while (checked < attachments.items.len) : (checked += 1) {
        const index = (attachments.next_send + checked) % attachments.items.len;
        const active = if (attachments.items[index]) |*value| value else continue;
        const pane = active.pane;
        if (pane.ingest_pending) continue;
        if (active.snapshot_pending) {
            const payload = (try encodeFrame(io, buffer, active, true, metrics)) orelse
                unreachable;
            active.snapshot_pending = false;
            try startSend(io, select, connection.?, payload, send_pending);
            attachments.next_send = (index + 1) % attachments.items.len;
            return;
        }
        if (active.outstanding_frame_id == 0 and pane.dirty) {
            if (try encodeFrame(io, buffer, active, false, metrics)) |payload| {
                try startSend(io, select, connection.?, payload, send_pending);
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
        }
        if (active.graphics_snapshot != .idle or active.transfer != null or
            active.observed_graphics_revision != pane.graphics_revision)
        {
            if (try encodeNextGraphics(buffer, active)) |payload| {
                if (comptime diagnostics.enabled) {
                    metrics.graphics_messages += 1;
                    metrics.graphics_bytes += payload.len;
                }
                try startSend(io, select, connection.?, payload, send_pending);
                attachments.next_send = (index + 1) % attachments.items.len;
                return;
            }
        }
        if (active.exit_sent or !pane.output_done or pane.exit == null) continue;
        if (active.outstanding_frame_id != 0) continue;

        const exit = pane.exit.?;
        const payload = try schema.encodePaneExited(buffer, .{
            .pane_id = pane.id,
            .kind = switch (exit) {
                .exited => .exited,
                .signaled => .signaled,
            },
            .value = switch (exit) {
                .exited => |status| status,
                .signaled => |signal| @intFromEnum(signal),
            },
        });
        try startSend(io, select, connection.?, payload, send_pending);
        active.exit_sent = true;
        sent_exit_pane.* = pane.id;
        attachments.next_send = (index + 1) % attachments.items.len;
        return;
    }
}

fn encodeHistoryResult(
    buffer: []u8,
    result: *const history.model.QueryResult,
    storage: *[history.model.max_results]schema.HistoryEntry,
) ![]const u8 {
    std.debug.assert(result.entries.len <= storage.len);
    for (result.entries, 0..) |entry, index| {
        storage[index] = .{
            .id = entry.id,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = switch (entry.status) {
                .completed => .completed,
                .interrupted => .interrupted,
            },
            .command = entry.command,
            .cwd = entry.cwd,
            .workspace_path = entry.workspace_path,
        };
    }
    return schema.encodeHistoryResults(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
    });
}

fn startSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    connection: *core.transport.SocketChannel,
    payload: []const u8,
    send_pending: *bool,
) !void {
    std.debug.assert(!send_pending.*);
    send_pending.* = true;
    select.concurrent(.client_sent, sendClient, .{ io, connection, payload }) catch |err| {
        send_pending.* = false;
        return err;
    };
}

fn connectionPointer(
    connection: *?core.transport.SocketChannel,
) ?*core.transport.SocketChannel {
    return if (connection.*) |*active| if (active.isActive()) active else null else null;
}

fn closeClient(
    io: Io,
    connection: *?core.transport.SocketChannel,
    read_pending: bool,
    send_pending: bool,
    attachments: *AttachmentStore,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
) void {
    if (connection.*) |*active| active.deinit(io);
    if (!read_pending and !send_pending) connection.* = null;
    dropAttachments(attachments, panes, workspaces);
}

fn dropAttachments(
    attachments: *AttachmentStore,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
) void {
    attachments.deinit();
    panes.collectFinished(attachments, workspaces, null) catch unreachable;
}

fn attachedPane(
    attachments: *AttachmentStore,
    message_id: schema.PaneId,
) !*Attachment {
    return attachments.find(message_id) orelse error.PaneNotFound;
}

fn sendClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
) anyerror!void {
    try connection.send(io, payload);
}

fn writeDiagnostics(
    io: Io,
    sink: *diagnostics.Sink,
    bytes: []const u8,
) anyerror!void {
    try sink.write(io, bytes);
}

fn historyClock(io: Io) history.osc.Clock {
    return .{
        .real_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
        .awake_ns = @intCast(Io.Timestamp.now(io, .awake).toNanoseconds()),
    };
}

fn formatRuntimeTelemetry(
    buffer: []u8,
    io: Io,
    metrics: *const RuntimeMetrics,
    attachments: *const AttachmentStore,
    workspace_count: usize,
    tab_count: usize,
    panes: *const PaneStore,
    history_service: *const history.Service,
) ![]const u8 {
    const now_ns = diagnostics.now(io);
    var outstanding_frames: usize = 0;
    var dirty_panes: usize = 0;
    var history_prompt_markers: u64 = 0;
    var history_input_markers: u64 = 0;
    var history_output_markers: u64 = 0;
    var history_finished_markers: u64 = 0;
    var history_osc_started: u64 = 0;
    var history_osc_finished: u64 = 0;
    var history_pty_submissions: u64 = 0;
    var history_pty_captures: u64 = 0;
    var history_pty_capture_failures: u64 = 0;
    var history_foreground_completions: u64 = 0;
    var history_next_input_completions: u64 = 0;
    var history_auxiliary_completions: u64 = 0;
    var graphics_images: usize = 0;
    var graphics_placements: usize = 0;
    var graphics_resident_bytes: usize = 0;
    var graphics_transfer_bytes: usize = 0;
    var graphics_loading_bytes: usize = 0;
    var pty_response_queue_depth: usize = 0;
    var pty_response_dropped: u64 = 0;
    for (panes.items) |slot| {
        const pane = slot orelse continue;
        if (pane.ingest_pending) continue;
        pty_response_queue_depth += pane.pty_responses.len;
        pty_response_dropped += pane.pty_responses.dropped;
        for (std.enums.values(vt.ScreenSet.Key)) |key| {
            const screen = pane.terminal.screens.get(key) orelse continue;
            graphics_images += screen.kitty_images.images.count();
            graphics_placements += screen.kitty_images.placements.count();
            graphics_resident_bytes += screen.kitty_images.total_bytes;
            if (screen.kitty_images.loading) |loading|
                graphics_loading_bytes += loading.data.items.len;
        }
    }
    for (attachments.items) |slot| {
        const active = slot orelse continue;
        if (active.pane.ingest_pending) continue;
        if (active.transfer) |transfer| {
            graphics_transfer_bytes += transfer.pixels.len;
            graphics_resident_bytes += transfer.pixels.len;
        }
        if (active.outstanding_frame_id != 0) outstanding_frames += 1;
        if (active.pane.dirty) dirty_panes += 1;
        history_prompt_markers += active.pane.history_tracker.aux.prompt_markers;
        history_input_markers += active.pane.history_tracker.aux.input_markers;
        history_output_markers += active.pane.history_tracker.aux.output_markers;
        history_finished_markers += active.pane.history_tracker.aux.finished_markers;
        history_osc_started += active.pane.history_tracker.aux.osc_started;
        history_osc_finished += active.pane.history_tracker.aux.osc_finished;
        history_pty_submissions += active.pane.history_tracker.submissions_armed;
        history_pty_captures += active.pane.history_tracker.submissions_captured;
        history_pty_capture_failures += active.pane.history_tracker.capture_failures;
        history_foreground_completions += active.pane.history_tracker.foreground_completions;
        history_next_input_completions += active.pane.history_tracker.next_input_completions;
        history_auxiliary_completions += active.pane.history_tracker.auxiliary_completions;
    }
    const history_stats = history_service.statsSnapshot();
    var output = Io.Writer.fixed(buffer);
    try output.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"runtime\"," ++
        "\"workspace_count\":{d},\"tab_count\":{d}," ++
        "\"pane_count\":{d},\"attachment_count\":{d}," ++
        "\"outstanding_frames\":{d},\"dirty_panes\":{d}," ++
        "\"client_messages\":{d},\"input_events\":{d},\"input_bytes\":{d}," ++
        "\"pty_events\":{d},\"pty_bytes\":{d},\"folded_pty_events\":{d}," ++
        "\"frames\":{d},\"frame_bytes\":{d},\"frame_cells\":{d}," ++
        "\"frame_spans\":{d},\"snapshots\":{d}," ++
        "\"cursor_only_frames\":{d},\"noop_frames\":{d}," ++
        "\"damaged_rows\":{d},\"diff_scanned_cells\":{d}," ++
        "\"coalesced_spans\":{d},\"bridged_cells\":{d}," ++
        "\"coalesced_bytes_saved\":{d},", .{
        now_ns / std.time.ns_per_ms,
        diagnostics.elapsed(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        workspace_count,
        tab_count,
        panes.count,
        attachments.count,
        outstanding_frames,
        dirty_panes,
        metrics.client_messages,
        metrics.input_events,
        metrics.input_bytes,
        metrics.pty_events,
        metrics.pty_bytes,
        metrics.folded_pty_events,
        metrics.frames,
        metrics.frame_bytes,
        metrics.frame_cells,
        metrics.frame_spans,
        metrics.snapshots,
        metrics.cursor_only_frames,
        metrics.noop_frames,
        metrics.damaged_rows,
        metrics.diff_scanned_cells,
        metrics.coalesced_spans,
        metrics.bridged_cells,
        metrics.coalesced_bytes_saved,
    });
    try output.print(
        "\"graphics_messages\":{d},\"graphics_bytes\":{d}," ++
            "\"graphics_images\":{d},\"graphics_placements\":{d}," ++
            "\"graphics_resident_bytes\":{d},\"graphics_transfer_bytes\":{d}," ++
            "\"graphics_loading_bytes\":{d}," ++
            "\"pty_response_queue_depth\":{d},\"pty_response_dropped\":{d},",
        .{
            metrics.graphics_messages,
            metrics.graphics_bytes,
            graphics_images,
            graphics_placements,
            graphics_resident_bytes,
            graphics_transfer_bytes,
            graphics_loading_bytes,
            pty_response_queue_depth,
            pty_response_dropped,
        },
    );
    try output.print("\"history_captured\":{d},\"history_dropped\":{d}," ++
        "\"history_candidate_input_bytes\":{d}," ++
        "\"history_prompt_markers\":{d},\"history_input_markers\":{d}," ++
        "\"history_output_markers\":{d},\"history_finished_markers\":{d}," ++
        "\"history_osc_started\":{d},\"history_osc_finished\":{d}," ++
        "\"history_pty_submissions\":{d},\"history_pty_captures\":{d}," ++
        "\"history_pty_capture_failures\":{d}," ++
        "\"history_foreground_completions\":{d}," ++
        "\"history_next_input_completions\":{d}," ++
        "\"history_auxiliary_completions\":{d},", .{
        metrics.history_captured,
        metrics.history_dropped,
        metrics.history_candidate_input_bytes,
        history_prompt_markers,
        history_input_markers,
        history_output_markers,
        history_finished_markers,
        history_osc_started,
        history_osc_finished,
        history_pty_submissions,
        history_pty_captures,
        history_pty_capture_failures,
        history_foreground_completions,
        history_next_input_completions,
        history_auxiliary_completions,
    });
    try output.print("\"history_queries\":{d},\"history_query_failures\":{d}," ++
        "\"history_queue_depth\":{d},\"history_queue_high_water\":{d}," ++
        "\"history_queue_dropped\":{d}," ++
        "\"sqlite_writes\":{d},\"sqlite_write_failures\":{d}," ++
        "\"sqlite_write_avg_us\":{d},\"sqlite_write_max_us\":{d}," ++
        "\"sqlite_queries\":{d},\"sqlite_query_failures\":{d}," ++
        "\"sqlite_query_avg_us\":{d},\"sqlite_query_max_us\":{d}," ++
        "\"input_write_avg_us\":{d},\"input_write_max_us\":{d}," ++
        "\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"ingest_avg_us\":{d},\"ingest_max_us\":{d}," ++
        "\"encode_avg_us\":{d},\"encode_max_us\":{d}," ++
        "\"ack_avg_us\":{d},\"ack_max_us\":{d}}}\n", .{
        metrics.history_queries,
        metrics.history_query_failures,
        history_stats.queued,
        history_stats.queue_high_water,
        history_stats.dropped,
        history_stats.sqlite_writes,
        history_stats.sqlite_write_failures,
        averageNs(history_stats.sqlite_write_ns, history_stats.sqlite_writes) / std.time.ns_per_us,
        history_stats.sqlite_write_max_ns / std.time.ns_per_us,
        history_stats.sqlite_queries,
        history_stats.sqlite_query_failures,
        averageNs(history_stats.sqlite_query_ns, history_stats.sqlite_queries) / std.time.ns_per_us,
        history_stats.sqlite_query_max_ns / std.time.ns_per_us,
        metrics.input_write.average() / std.time.ns_per_us,
        metrics.input_write.max_ns / std.time.ns_per_us,
        metrics.decode.average() / std.time.ns_per_us,
        metrics.decode.max_ns / std.time.ns_per_us,
        metrics.ingest.average() / std.time.ns_per_us,
        metrics.ingest.max_ns / std.time.ns_per_us,
        metrics.encode.average() / std.time.ns_per_us,
        metrics.encode.max_ns / std.time.ns_per_us,
        metrics.ack.average() / std.time.ns_per_us,
        metrics.ack.max_ns / std.time.ns_per_us,
    });
    return output.buffered();
}

fn averageNs(total: u64, count: u64) u64 {
    return if (count == 0) 0 else total / count;
}

fn writePaneInput(io: Io, pane: *Pane, bytes: []const u8, started_ns: u64) PaneInputEvent {
    pane.pty_write_mutex.lockUncancelable(io);
    defer pane.pty_write_mutex.unlock(io);
    return .{
        .started_ns = started_ns,
        .result = pane.session.file().writeStreamingAll(io, bytes),
    };
}

fn schedulePaneResponse(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    pane: *Pane,
) !void {
    if (pane.response_pending) return;
    const response = pane.pty_responses.peek() orelse return;
    pane.response_pending = true;
    select.concurrent(.pane_response_written, writePaneResponse, .{
        io,
        pane,
        response,
    }) catch |err| {
        pane.response_pending = false;
        return err;
    };
}

fn writePaneResponse(io: Io, pane: *Pane, bytes: []const u8) PaneResponseEvent {
    pane.pty_write_mutex.lockUncancelable(io);
    defer pane.pty_write_mutex.unlock(io);
    return .{
        .pane = pane,
        .result = pane.session.file().writeStreamingAll(io, bytes),
    };
}

fn waitForStop(io: Io, stop: *Io.Queue(u8)) anyerror!void {
    _ = try stop.getOne(io);
}

fn acceptClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    var connection = try listener.accept(io);
    errdefer connection.deinit(io);
    const response = try transport.handshake.perform(io, &connection);
    return switch (response) {
        .accepted => connection,
        .rejected => error.IncompatibleProtocol,
    };
}

fn receiveClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn readPane(io: Io, pane: *Pane) PaneOutputEvent {
    const len = pane.session.file().readStreaming(io, &.{&pane.output_buffer}) catch |err|
        return .{ .pane = pane, .result = err };
    return .{ .pane = pane, .result = @intCast(len) };
}

fn ingestPane(
    io: Io,
    pane: *Pane,
    output_len: u16,
    ingest_gate: ?*IngestTestGate,
) PaneIngestEvent {
    if (ingest_gate) |gate| gate.wait(io) catch |err|
        return .{ .pane = pane, .result = err };
    var stats: PaneIngestStats = .{};
    stats.history_input_bytes = pane.processHistoryInput(&stats);
    stats.elapsed_ns = pane.ingest(io, pane.output_buffer[0..output_len], &stats) catch |err|
        return .{ .pane = pane, .result = err };
    return .{ .pane = pane, .result = stats };
}

fn waitPane(pane: *Pane) PaneExitEvent {
    const result = pane.session.wait();
    return .{ .pane = pane, .result = result };
}

test "graphics allocator reserves pane and global bytes before allocation" {
    var budget = GraphicsBudget.init(64);
    var first = PaneMediaAllocator.init(std.testing.allocator, &budget, 48);
    var second = PaneMediaAllocator.init(std.testing.allocator, &budget, 48);
    const first_allocator = first.allocator();
    const second_allocator = second.allocator();

    const a = try first_allocator.alloc(u8, 40);
    defer first_allocator.free(a);
    const b = try second_allocator.alloc(u8, 24);
    defer second_allocator.free(b);
    try std.testing.expectError(error.OutOfMemory, second_allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 64), budget.used);
    try std.testing.expectEqual(@as(usize, 40), first.used);
    try std.testing.expectEqual(@as(usize, 24), second.used);
}

test "frozen graphics transfers use the same reservation as VT media" {
    var budget = GraphicsBudget.init(64);
    var media = PaneMediaAllocator.init(std.testing.allocator, &budget, 64);
    const allocator = media.allocator();
    const decoded = try allocator.alloc(u8, 40);
    defer allocator.free(decoded);

    try std.testing.expect(media.reserveManual(24));
    try std.testing.expect(!media.reserveManual(1));
    media.releaseManual(24);
    try std.testing.expectEqual(@as(usize, 40), budget.used);
}

test "workspace and default tab identities are stable per path" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const first = try store.ensure("/work/project");
    const same = try store.ensure("/work/project");
    const other = try store.ensure("/work/other");

    try std.testing.expect(first.created);
    try std.testing.expect(!same.created);
    try std.testing.expect(other.created);
    try std.testing.expectEqualDeep(first.location, same.location);
    try std.testing.expect(!std.meta.eql(first.location, other.location));
    try std.testing.expect(store.contains(first.location));
    var unknown_tab = first.location;
    unknown_tab.tab_id = try schema.id.tab(999);
    try std.testing.expect(!store.contains(unknown_tab));
    try std.testing.expectEqual(@as(usize, 2), store.count);
}

test "an uncommitted workspace can be rolled back" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();

    const workspace = try store.ensure("/invalid/cwd");
    const workspace_id = switch (workspace.location.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    store.remove(workspace_id);

    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "workspace tabs create rename reorder and close" {
    var store = WorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    const ensured = try store.ensure("/work/project");
    var label_buffer: [schema.max_tab_label_bytes]u8 = undefined;
    const logs = try store.createTab(ensured.location.workspace, "logs", &label_buffer);
    const generated = try store.createTab(ensured.location.workspace, "", &label_buffer);

    try std.testing.expectEqual(@as(u16, 1), logs.position);
    try std.testing.expectEqual(@as(u16, 2), generated.position);
    try std.testing.expectEqualStrings("tab 3", store.findTab(generated.location).?.labelSlice());

    store.findTab(logs.location).?.setLabel("server");
    try std.testing.expectEqualStrings("server", store.findTab(logs.location).?.labelSlice());
    const workspace = store.find(ensured.location.workspace).?;
    try std.testing.expectEqual(@as(u16, 0), workspace.moveTab(logs.location.tab_id, .previous).?);
    try std.testing.expectEqual(logs.location.tab_id, workspace.defaultTab());

    var panes: PaneStore = .{};
    var descriptors: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    const snapshot = store.descriptors(
        ensured.location.workspace,
        &panes,
        &descriptors,
    ).?;
    try std.testing.expectEqual(@as(usize, 3), snapshot.len);
    try std.testing.expectEqualStrings("server", snapshot[0].label);

    try std.testing.expectEqual(false, store.removeTab(logs.location).?);
    try std.testing.expectEqual(false, store.removeTab(generated.location).?);
    try std.testing.expectEqual(true, store.removeTab(ensured.location).?);
    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "Kitty framing counter survives splits and ignores other APCs" {
    var counter: KittyFramingCounter = .{};
    try std.testing.expectEqual(@as(usize, 0), counter.observe("text\x1b_Gm=1;AA"));
    try std.testing.expectEqual(@as(usize, 1), counter.observe("AA\x1b\\"));
    try std.testing.expectEqual(@as(usize, 0), counter.observe("\x1b_Xnot-kitty\x1b\\"));
    try std.testing.expectEqual(@as(usize, 2), counter.observe(
        "\x1b_Gm=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\",
    ));
}

test "runtime VT answers KGP queries and decodes terminal-browser zlib RGBA" {
    const Capture = struct {
        var bytes: [512]u8 = undefined;
        var len: usize = 0;

        fn reset() void {
            len = 0;
        }

        fn writePty(_: *vt.TerminalStream.Handler, response: [:0]const u8) void {
            if (len + response.len > bytes.len) @panic("KGP test response overflow");
            @memcpy(bytes[len..][0..response.len], response);
            len += response.len;
        }
    };

    var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = core.graphics.max_image_bytes_per_screen,
        .kitty_image_loading_limits = .direct,
    });
    defer terminal.deinit(std.testing.allocator);
    var handler = terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, core.graphics.max_encoded_chunk_bytes);
    handler.effects.write_pty = Capture.writePty;
    var stream = vt.TerminalStream.init(.{
        .allocator = std.testing.allocator,
        .handler = handler,
    });
    defer stream.deinit();

    Capture.reset();
    stream.nextSlice("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    try std.testing.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", Capture.bytes[0..Capture.len]);
    try std.testing.expectEqual(@as(usize, 0), terminal.screens.active.kitty_images.images.count());

    // Same encoding shape as terminal-browser: direct RGBA, zlib level 1,
    // independently base64-encoded chunks.
    Capture.reset();
    stream.nextSlice("\x1b_Ga=t,f=32,o=z,s=1,v=1,t=d,i=7,m=1;eAFjZGL+\x1b\\");
    stream.nextSlice("\x1b_Gm=0;DwABEwEG\x1b\\");
    const image = terminal.screens.active.kitty_images.imageById(7).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data.bytes().?);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=32,o=z,s=1,v=1,t=d,i=8;eAFjZGIGAAANAAc=\x1b\\");
    try std.testing.expect(std.mem.indexOf(
        u8,
        Capture.bytes[0..Capture.len],
        "EINVAL: invalid data",
    ) != null);
    try std.testing.expect(terminal.screens.active.kitty_images.imageById(8) == null);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=24,s=1,v=1,t=f,i=9;L3RtcC9pbWFnZQ==\x1b\\");
    try std.testing.expect(std.mem.indexOf(
        u8,
        Capture.bytes[0..Capture.len],
        "EINVAL: unsupported medium",
    ) != null);
}
