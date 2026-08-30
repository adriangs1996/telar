//! One runtime pane: its process, PTY, emulator, buffers, and quotas.
//!
//! Split out of `runtime.zig`; ownership rules are unchanged. The runtime
//! event loop drives these panes through `PaneStore`. Actor results cross back
//! into that owner as `PaneKey` values, never as mutable pane pointers.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_process = @import("../process/root.zig");
const history = @import("../history/root.zig");
pub const blit = @import("blit.zig");
pub const damage = @import("damage.zig");
const escape = history.escape;
const media_mod = @import("../media/root.zig");
const pty = @import("../pty/root.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub const max_panes = schema.max_panes_per_tab;

pub const output_chunk_size = 16 * 1024;

pub const max_pty_response_bytes = 1024;

pub const max_pty_responses = 64;

/// Retained VT history per pane. This matches herdr's default and stays a byte
/// quota so wide, styled terminal rows are charged for what they retain.
pub const default_scrollback_bytes = 10_000_000;

/// How long a child's synchronized-output block (DEC mode 2026) may hold
/// frames back before it is ignored. Same value ghostty uses to reset the
/// mode when a program forgets to close its block.
pub const max_sync_hold_ns = 1000 * std.time.ns_per_ms;

/// Stable identity for work that can finish after the pane lifecycle moved
/// on. Generation makes future id reuse safe without changing actor events.
pub const PaneKey = struct {
    id: schema.PaneId,
    generation: u64,
};

/// Fact produced when the runtime owns a discoverable pane and its actors.
pub const PaneLaunched = struct {
    key: PaneKey,
    location: schema.TabLocation,
};

pub const LaunchState = enum {
    starting,
    running,
    aborting,

    pub fn commit(state: *LaunchState) void {
        std.debug.assert(state.* == .starting);
        state.* = .running;
    }

    pub fn abort(state: *LaunchState) void {
        std.debug.assert(state.* == .starting);
        state.* = .aborting;
    }

    pub fn discoverable(state: LaunchState) bool {
        return state == .running;
    }
};

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

/// Cross-thread lock shared by the runtime thread and pane actors. A parking
/// pthread mutex rather than a spin loop: a descheduled holder must not make
/// the other side burn a core, and the media-allocator call sites have no
/// `Io` for an `Io.Mutex`.
pub const ParkingMutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn lock(mutex: *ParkingMutex) void {
        const rc = std.c.pthread_mutex_lock(&mutex.inner);
        std.debug.assert(rc == .SUCCESS);
    }

    pub fn unlock(mutex: *ParkingMutex) void {
        const rc = std.c.pthread_mutex_unlock(&mutex.inner);
        std.debug.assert(rc == .SUCCESS);
    }
};

pub const GraphicsBudget = struct {
    mutex: ParkingMutex = .{},
    limit: usize,
    used: usize = 0,

    pub fn init(limit: usize) GraphicsBudget {
        return .{ .limit = limit };
    }

    pub fn reserve(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) bool {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        const pane_next = std.math.add(usize, pane.used, bytes) catch return false;
        const global_next = std.math.add(usize, budget.used, bytes) catch return false;
        if (pane_next > pane.limit or global_next > budget.limit) return false;
        pane.used = pane_next;
        budget.used = global_next;
        return true;
    }

    pub fn release(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) void {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        std.debug.assert(bytes <= pane.used and bytes <= budget.used);
        pane.used -= bytes;
        budget.used -= bytes;
    }

    pub fn releaseAll(budget: *GraphicsBudget, pane: *PaneMediaAllocator) void {
        budget.mutex.lock();
        defer budget.mutex.unlock();
        std.debug.assert(pane.used <= budget.used);
        budget.used -= pane.used;
        pane.used = 0;
    }
};

/// Allocator used by VT stream effects and KGP. Charging allocations before
/// forwarding them to the child allocator makes compressed input, decoded
/// pixels, parser buffers and IPC transfer snapshots obey one hard budget.
pub const PaneMediaAllocator = struct {
    child: std.mem.Allocator,
    budget: *GraphicsBudget,
    limit: usize,
    used: usize = 0,

    pub fn init(child: std.mem.Allocator, budget: *GraphicsBudget, limit: usize) PaneMediaAllocator {
        return .{ .child = child, .budget = budget, .limit = limit };
    }

    pub fn allocator(media: *PaneMediaAllocator) std.mem.Allocator {
        return .{ .ptr = media, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    pub fn reserveManual(media: *PaneMediaAllocator, bytes: usize) bool {
        return media.budget.reserve(media, bytes);
    }

    pub fn releaseManual(media: *PaneMediaAllocator, bytes: usize) void {
        media.budget.release(media, bytes);
    }

    pub fn detach(media: *PaneMediaAllocator) void {
        media.budget.releaseAll(media);
    }

    pub fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const media: *PaneMediaAllocator = @ptrCast(@alignCast(context));
        if (!media.reserveManual(len)) return null;
        return media.child.rawAlloc(len, alignment, ret_addr) orelse {
            media.releaseManual(len);
            return null;
        };
    }

    pub fn resize(
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

    pub fn remap(
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

    pub fn free(
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

pub const PaneIngestStats = struct {
    elapsed_ns: u64 = 0,
};

pub const PtyResponseQueue = struct {
    mutex: ParkingMutex = .{},
    bytes: [max_pty_responses][max_pty_response_bytes]u8 = undefined,
    lengths: [max_pty_responses]u16 = @splat(0),
    head: u8 = 0,
    len: u8 = 0,
    dropped: u64 = 0,

    pub fn push(queue: *PtyResponseQueue, response: []const u8) bool {
        queue.mutex.lock();
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

    pub fn peek(queue_const: *const PtyResponseQueue) ?[]const u8 {
        const queue: *PtyResponseQueue = @constCast(queue_const);
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.len == 0) return null;
        return queue.bytes[queue.head][0..queue.lengths[queue.head]];
    }

    pub fn pop(queue: *PtyResponseQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        std.debug.assert(queue.len != 0);
        queue.lengths[queue.head] = 0;
        queue.head = @intCast((@as(usize, queue.head) + 1) % max_pty_responses);
        queue.len -= 1;
    }

    pub fn clear(queue: *PtyResponseQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        queue.lengths = @splat(0);
        queue.head = 0;
        queue.len = 0;
    }
};

/// Bytes typed at a child that has not accepted them yet.
///
/// Only the runtime thread mutates this queue; the input-writer actor merely
/// reads the stable chunk it was handed, so no lock is needed. The bound is
/// the explicit backpressure policy: a child that stops draining its PTY for
/// this many bytes is wedged, and dropping its typed-ahead input - counted -
/// mirrors terminal flow control. The alternative, pausing the client socket,
/// froze every other pane's input behind one blocked PTY write.
pub const PaneInputQueue = struct {
    pub const capacity = 2 * schema.max_input_bytes;

    bytes: [capacity]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped_bytes: u64 = 0,

    /// All-or-nothing: partial keystroke sequences would corrupt the child's
    /// input stream, so a message that does not fit is dropped whole.
    pub fn push(queue: *PaneInputQueue, input: []const u8) bool {
        if (input.len > queue.bytes.len - queue.len) {
            queue.dropped_bytes +|= input.len;
            return false;
        }
        var offset: usize = 0;
        while (offset < input.len) {
            const index = (queue.head + queue.len + offset) % queue.bytes.len;
            const run = @min(input.len - offset, queue.bytes.len - index);
            @memcpy(queue.bytes[index..][0..run], input[offset..][0..run]);
            offset += run;
        }
        queue.len += input.len;
        return true;
    }

    /// The next contiguous run to hand to the PTY writer. Stays valid until
    /// `consume`: a wrap-around `push` never writes into `[head, head+len)`.
    pub fn nextChunk(queue: *const PaneInputQueue) ?[]const u8 {
        if (queue.len == 0) return null;
        const run = @min(queue.len, queue.bytes.len - queue.head);
        return queue.bytes[queue.head..][0..run];
    }

    pub fn consume(queue: *PaneInputQueue, count: usize) void {
        std.debug.assert(count <= queue.len);
        queue.head = (queue.head + count) % queue.bytes.len;
        queue.len -= count;
    }

    pub fn clear(queue: *PaneInputQueue) void {
        queue.head = 0;
        queue.len = 0;
    }
};

pub const PtyWriteResult = enum {
    succeeded,
    failed,
};

pub const KittyFramingCounter = escape.KittyFramingCounter;

pub const CwdState = struct {
    bytes: [schema.max_cwd_bytes]u8 = undefined,
    len: u16 = 0,
    revision: u64 = 1,

    pub fn init(path: []const u8) !CwdState {
        var state: CwdState = .{};
        if (!state.set(path)) return error.InvalidCwd;
        return state;
    }

    pub fn slice(state: *const CwdState) []const u8 {
        return state.bytes[0..state.len];
    }

    /// Invalid observations and repeated values are ignored. The fixed buffer
    /// makes updates allocation-free and keeps every wire value bounded.
    pub fn update(state: *CwdState, path: []const u8) bool {
        if (!validCwd(path) or std.mem.eql(u8, state.slice(), path)) return false;
        @memcpy(state.bytes[0..path.len], path);
        state.len = @intCast(path.len);
        state.revision +%= 1;
        if (state.revision == 0) state.revision = 1;
        return true;
    }

    fn set(state: *CwdState, path: []const u8) bool {
        if (!validCwd(path)) return false;
        @memcpy(state.bytes[0..path.len], path);
        state.len = @intCast(path.len);
        return true;
    }

    fn validCwd(path: []const u8) bool {
        return path.len != 0 and path.len <= schema.max_cwd_bytes and
            std.mem.indexOfScalar(u8, path, 0) == null;
    }
};

pub const Pane = struct {
    id: schema.PaneId,
    generation: u64,
    location: schema.TabLocation,
    launch_state: LaunchState = .starting,
    session: pty.Session,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    media: media_mod.Pipeline,
    pty_responses: PtyResponseQueue = .{},
    kitty_framing: KittyFramingCounter = .{},
    kitty_loading_chunks: usize = 0,
    graphics_limits: GraphicsLimits,
    graphics_storage_limit: usize,
    media_allocator: PaneMediaAllocator,
    pty_write_mutex: Io.Mutex = .init,
    response_pending: bool = false,
    input_queue: PaneInputQueue = .{},
    input_write_pending: bool = false,
    input_write_len: usize = 0,
    size: schema.TerminalSize,
    render_state: vt.RenderState = .empty,
    screen: core.ui.Buffer,
    damaged_rows: []bool,
    output_buffer: [output_chunk_size]u8 = undefined,
    cursor: schema.frame.Cursor = .{},
    mouse: schema.frame.Mouse = .{},
    input_modes: schema.frame.InputModes = .{},
    foreground_override: ?vt.color.RGB = null,
    background_override: ?vt.color.RGB = null,
    semantic_colors_dirty: bool = false,
    graphics_revision: u64 = 0,
    graphics_present: bool = false,
    dirty: bool = true,
    render_pending: bool = true,
    cell_revision: u64 = 1,
    output_pending: bool = false,
    ingest_pending: bool = false,
    actor_count: u8 = 0,
    output_done: bool = false,
    wait_pending: bool = false,
    close_requested: bool = false,
    exit: ?pty.Exit = null,
    history_service: *history.Service,
    history_observer: history.observer.Observer,
    agent_process_cache: agent_process.Cache = .{},
    foreground_revision: u64 = 1,
    history_session_id: history.SessionId,
    started_at_ms: i64,
    history_sequence: u64 = 0,
    history_session_started: bool = false,
    history_session_finished: bool = false,
    history_exit_queued: bool = false,
    workspace_path: []u8,
    cwd: CwdState,
    pending_size: ?schema.TerminalSize = null,
    /// When the child's synchronized-output block started holding frames
    /// back, null while no hold is active. See `holdFrames`.
    sync_hold_started_ns: ?u64 = null,
    io: Io,
    gpa: std.mem.Allocator,

    pub fn create(
        io: Io,
        gpa: std.mem.Allocator,
        identity: PaneKey,
        location: schema.TabLocation,
        command: *const pty.Command,
        launch_cwd: []const u8,
        workspace_path: []const u8,
        history_service: *history.Service,
        size: schema.TerminalSize,
        graphics_limits: GraphicsLimits,
        graphics_budget: *GraphicsBudget,
    ) !*Pane {
        const pane = try gpa.create(Pane);
        errdefer gpa.destroy(pane);

        const workspace_copy = try gpa.dupe(u8, workspace_path);
        errdefer gpa.free(workspace_copy);

        // `gpa.create` returns undefined memory, so declared defaults do not
        // apply on their own; the struct literal makes the compiler enforce
        // that every remaining field is either defaulted or listed here. The
        // handler-bearing fields stay `undefined` until the pane has its
        // final address, because the VT handler captures `&pane.terminal`.
        pane.* = .{
            .id = identity.id,
            .generation = identity.generation,
            .location = location,
            .io = io,
            .gpa = gpa,
            .history_service = history_service,
            .graphics_limits = graphics_limits,
            .graphics_storage_limit = graphics_limits.pane_bytes / 2,
            .media_allocator = .init(gpa, graphics_budget, graphics_limits.pane_bytes),
            .history_session_id = history_service.newSessionId(io),
            .started_at_ms = 0,
            .workspace_path = workspace_copy,
            .cwd = try .init(launch_cwd),
            .session = undefined,
            .size = size,
            .terminal = undefined,
            .stream = undefined,
            .media = undefined,
            .history_observer = undefined,
            .agent_process_cache = .init(std.mem.span(command.file)),
            .screen = undefined,
            .damaged_rows = undefined,
        };
        pane.terminal = try .init(io, gpa, .{
            .cols = size.cols,
            .rows = size.rows,
            .max_scrollback_bytes = default_scrollback_bytes,
            .kitty_image_storage_limit = 0,
            .kitty_image_loading_limits = .direct,
        });
        errdefer pane.terminal.deinit(gpa);
        errdefer pane.render_state.deinit(gpa);
        var handler = pane.terminal.vtHandler();
        handler.apc_handler.enable(.kitty, false);
        handler.effects.write_pty = Pane.writePty;
        handler.effects.size = Pane.reportSize;
        pane.stream = vt.TerminalStream.init(.{
            .allocator = gpa,
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
        try pane.media.init(
            io,
            pane.media_allocator.allocator(),
            size,
            @min(core.graphics.max_image_bytes_per_screen, graphics_limits.pane_bytes / 2),
            graphics_limits.payload_bytes,
            Pane.writeMediaPty,
        );
        errdefer pane.media.deinit();
        try pane.history_observer.init(io, gpa, launch_cwd, size);
        errdefer pane.history_observer.deinit();
        pane.screen = try .init(gpa, size.cols, size.rows);
        errdefer pane.screen.deinit();
        pane.damaged_rows = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(pane.damaged_rows);
        @memset(pane.damaged_rows, false);
        pane.foreground_override = pane.terminal.colors.foreground.override;
        pane.background_override = pane.terminal.colors.background.override;
        pane.mouse = pane.mouseState();
        pane.input_modes = pane.inputModeState();
        try pane.render(true);

        // Spawn last. Once the child exists, Pane.create cannot fail and
        // erase evidence that a process ran before launch commit.
        pane.session = try .spawn(command, .{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        });
        pane.started_at_ms = Io.Timestamp.now(io, .real).toMilliseconds();
        return pane;
    }

    pub fn commitLaunch(pane: *Pane, shell: []const u8) void {
        pane.launch_state.commit();
        pane.history_session_started = pane.history_service.startSession(
            pane.io,
            pane.history_session_id,
            pane.id,
            pane.location,
            pane.workspace_path,
            shell,
            pane.started_at_ms,
        );
    }

    pub fn abortLaunch(pane: *Pane) void {
        pane.launch_state.abort();
        _ = pane.requestClose();
    }

    /// Requests PTY shutdown exactly once. Pane retirement remains owned by
    /// the later exit event and actor-drain lifecycle.
    ///
    /// ```zig
    /// const started = pane.requestClose();
    /// ```
    pub fn requestClose(pane: *Pane) bool {
        if (pane.close_requested) {
            return false;
        }

        pane.close_requested = true;
        pane.session.shutdown();
        return true;
    }

    pub fn mouseState(pane: *const Pane) schema.frame.Mouse {
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

    pub fn key(pane: *const Pane) PaneKey {
        return .{ .id = pane.id, .generation = pane.generation };
    }

    /// Ghostty's page allocator size: the same counter `max_scrollback_bytes`
    /// prunes against, covering the active grid plus retained history.
    pub fn vtScrollbackBytes(pane: *const Pane) usize {
        var total: usize = 0;
        for (std.enums.values(vt.ScreenSet.Key)) |screen_key| {
            const screen = pane.terminal.screens.get(screen_key) orelse continue;
            total += screen.pages.page_size;
        }
        return total;
    }

    pub fn vtScreenBytes(pane: *const Pane) usize {
        return pane.screen.cells.len * @sizeOf(core.ui.Cell);
    }

    pub fn actorStarted(pane: *Pane) void {
        std.debug.assert(pane.actor_count < 8);
        pane.actor_count += 1;
    }

    pub fn actorFinished(pane: *Pane) void {
        std.debug.assert(pane.actor_count != 0);
        pane.actor_count -= 1;
    }

    pub fn inputModeState(pane: *const Pane) schema.frame.InputModes {
        const modes = &pane.terminal.modes;
        return .{
            .cursor_keys = modes.get(.cursor_keys),
            .keypad_keys = modes.get(.keypad_keys),
            .bracketed_paste = modes.get(.bracketed_paste),
            .focus_events = modes.get(.focus_event),
            .alternate_scroll = modes.get(.mouse_alternate_scroll),
            .alternate_screen = pane.terminal.screens.active_key == .alternate,
            .kitty_keyboard_flags = pane.terminal.screens.active.kitty_keyboard.current().int(),
            .modify_other_keys_2 = pane.terminal.flags.modify_other_keys_2,
        };
    }

    pub fn destroy(pane: *Pane) void {
        const gpa = pane.gpa;
        pane.finishHistory();
        gpa.free(pane.workspace_path);
        gpa.free(pane.damaged_rows);
        pane.screen.deinit();
        pane.render_state.deinit(gpa);
        pane.history_observer.deinit();
        pane.media.deinit();
        pane.stream.deinit();
        pane.media_allocator.detach();
        pane.terminal.deinit(gpa);
        pane.session.deinit();
        gpa.destroy(pane);
    }

    pub fn ingest(pane: *Pane, io: Io, bytes: []const u8) !u64 {
        const started = diagnostics.now(io);
        {
            const terminal_allocations = diagnostics.enterTerminalAllocations();
            defer terminal_allocations.restore();
            pane.stream.nextSlice(bytes);
        }
        const foreground = pane.terminal.colors.foreground.override;
        const background = pane.terminal.colors.background.override;
        pane.mouse = pane.mouseState();
        pane.input_modes = pane.inputModeState();
        if (!std.meta.eql(pane.foreground_override, foreground) or
            !std.meta.eql(pane.background_override, background))
        {
            pane.foreground_override = foreground;
            pane.background_override = background;
            pane.semantic_colors_dirty = true;
        }
        pane.render_pending = true;
        pane.dirty = true;
        return diagnostics.elapsed(started, diagnostics.now(io));
    }

    pub fn queueMediaOutput(pane: *Pane, bytes: []const u8) void {
        pane.media.queueOutput(bytes);
    }

    pub fn processMedia(
        pane: *Pane,
        current_size: schema.TerminalSize,
        stats: *media_mod.Stats,
    ) void {
        if (pane.media.batches[pane.media.worker.?].reset_before) {
            pane.kitty_framing = .{};
            pane.kitty_loading_chunks = 0;
        }
        pane.media.processSealed(current_size, stats, pane, ingestMediaOutput);
    }

    fn ingestMediaOutput(pane: *Pane, bytes: []const u8) void {
        const loading_id = if (pane.media.terminal.screens.active.kitty_images.loading) |loading|
            loading.image.id
        else
            null;
        const kitty_commands = pane.kitty_framing.observe(bytes);
        pane.media.stream.nextSlice(bytes);
        pane.enforceIncompleteGraphics(pane.io, loading_id, kitty_commands);
    }

    pub fn queueHistoryInput(
        pane: *Pane,
        bytes: []const u8,
        shell_foreground: bool,
        clock: history.Clock,
    ) void {
        pane.history_observer.queueInput(bytes, shell_foreground, clock);
    }

    /// Enqueues one complete client message for the PTY writer or records the
    /// complete message as dropped when the bounded queue has no room.
    ///
    /// ```zig
    /// const queued = pane.queuePtyInput(bytes);
    /// ```
    pub fn queuePtyInput(pane: *Pane, bytes: []const u8) bool {
        return pane.input_queue.push(bytes);
    }

    /// Borrows the head response until one asynchronous write settles.
    /// Producers may append behind it, but no second consumer can start.
    ///
    /// ```zig
    /// const response = pane.beginPtyResponseWrite() orelse return;
    /// ```
    pub fn beginPtyResponseWrite(pane: *Pane) ?[]const u8 {
        if (pane.response_pending) {
            return null;
        }

        const response = pane.pty_responses.peek() orelse return null;
        pane.response_pending = true;
        pane.actorStarted();
        return response;
    }

    /// Releases the response borrow, removing only the written head on
    /// success or clearing a queue that can no longer reach the child.
    ///
    /// ```zig
    /// pane.completePtyResponseWrite(.succeeded);
    /// ```
    pub fn completePtyResponseWrite(pane: *Pane, result: PtyWriteResult) void {
        std.debug.assert(pane.response_pending);

        pane.response_pending = false;
        pane.actorFinished();

        switch (result) {
            .succeeded => pane.pty_responses.pop(),
            .failed => pane.pty_responses.clear(),
        }
    }

    /// Rolls back a response whose actor could not be scheduled, preserving
    /// the queue head for the next attempt.
    ///
    /// ```zig
    /// pane.cancelPtyResponseWrite();
    /// ```
    pub fn cancelPtyResponseWrite(pane: *Pane) void {
        std.debug.assert(pane.response_pending);

        pane.response_pending = false;
        pane.actorFinished();
    }

    /// Borrows the next stable queue chunk for one asynchronous PTY write.
    /// Repeated calls return null until that write completes or is cancelled.
    ///
    /// ```zig
    /// const bytes = pane.beginPtyInputWrite() orelse return;
    /// ```
    pub fn beginPtyInputWrite(pane: *Pane) ?[]const u8 {
        if (pane.input_write_pending) {
            return null;
        }

        const bytes = pane.input_queue.nextChunk() orelse return null;
        pane.input_write_pending = true;
        pane.input_write_len = bytes.len;
        pane.actorStarted();
        return bytes;
    }

    /// Releases the in-flight write borrow, consuming its exact queue prefix
    /// on success or stopping and clearing the input pump on PTY failure.
    ///
    /// ```zig
    /// pane.completePtyInputWrite(.succeeded);
    /// ```
    pub fn completePtyInputWrite(pane: *Pane, result: PtyWriteResult) void {
        std.debug.assert(pane.input_write_pending);
        std.debug.assert(pane.input_write_len != 0);

        const written = pane.input_write_len;
        pane.input_write_pending = false;
        pane.input_write_len = 0;
        pane.actorFinished();

        switch (result) {
            .succeeded => pane.input_queue.consume(written),
            .failed => pane.input_queue.clear(),
        }
    }

    /// Rolls back a write that could not be scheduled without consuming the
    /// bytes, allowing a later scheduling attempt to retry the same prefix.
    ///
    /// ```zig
    /// pane.cancelPtyInputWrite();
    /// ```
    pub fn cancelPtyInputWrite(pane: *Pane) void {
        std.debug.assert(pane.input_write_pending);
        std.debug.assert(pane.input_write_len != 0);

        pane.input_write_pending = false;
        pane.input_write_len = 0;
        pane.actorFinished();
    }

    pub fn queueHistoryOutput(
        pane: *Pane,
        bytes: []const u8,
        shell_foreground: ?bool,
        clock: history.Clock,
    ) void {
        pane.history_observer.queueOutput(bytes, shell_foreground, clock);
    }

    pub fn processHistoryObservation(
        pane: *Pane,
        current_size: schema.TerminalSize,
        stats: *history.observer.Stats,
    ) void {
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pane.session.cwd(&cwd_buffer);
        var capture_context: CaptureContext = .{ .pane = pane, .observation_stats = stats };
        pane.history_observer.processSealed(
            cwd,
            current_size,
            stats,
            &capture_context,
            captureCommand,
        );
    }

    pub fn updateObservedCwd(pane: *Pane) bool {
        return pane.cwd.update(pane.history_observer.currentCwd());
    }

    pub fn enforceIncompleteGraphics(
        pane: *Pane,
        io: Io,
        previous_loading_id: ?u32,
        completed_commands: usize,
    ) void {
        const storage = &pane.media.terminal.screens.active.kitty_images;
        if (previous_loading_id != null or storage.loading != null)
            pane.kitty_loading_chunks +|= completed_commands
        else
            pane.kitty_loading_chunks = 0;

        const chunk_limit_exceeded = pane.kitty_loading_chunks > pane.graphics_limits.chunks_per_image;
        const loading = storage.loading orelse {
            if (chunk_limit_exceeded) if (previous_loading_id) |image_id| {
                storage.delete(io, pane.media_allocator.allocator(), &pane.media.terminal, .{ .id = .{
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

    pub fn queueGraphicsLimitResponse(pane: *Pane, image_id: u32) void {
        var response: [128]u8 = undefined;
        const bytes = std.fmt.bufPrint(
            &response,
            "\x1b_Gi={d};ENOMEM: graphics upload limit exceeded\x1b\\",
            .{image_id},
        ) catch return;
        _ = pane.pty_responses.push(bytes);
    }

    pub fn observeGraphicsDamage(pane: *Pane) void {
        const storage = &pane.media.terminal.screens.active.kitty_images;
        if (!storage.dirty) return;
        pane.graphics_revision +%= 1;
        if (pane.graphics_revision == 0) pane.graphics_revision = 1;
        storage.dirty = false;
    }

    pub fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const pane: *Pane = @fieldParentPtr("stream", stream);
        _ = pane.pty_responses.push(response);
    }

    pub fn writeMediaPty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
        if (!std.mem.startsWith(u8, response, "\x1b_G")) return;
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        const media: *media_mod.Pipeline = @fieldParentPtr("stream", stream);
        const pane: *Pane = @fieldParentPtr("media", media);
        _ = pane.pty_responses.push(response);
    }

    pub fn reportSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
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

    pub const CaptureContext = struct {
        pane: *Pane,
        observation_stats: ?*history.observer.Stats = null,
    };

    pub fn captureCommand(context: *CaptureContext, command: history.Command) void {
        const pane = context.pane;
        if (!pane.history_session_started) return;
        pane.history_sequence += 1;
        const submitted = pane.history_service.recordCommand(pane.io, .{
            .session_id = pane.history_session_id,
            .pane_id = pane.id,
            .location = pane.location,
            .sequence = pane.history_sequence,
            .workspace_path = pane.workspace_path,
            .cols = pane.history_observer.terminal.cols,
            .rows = pane.history_observer.terminal.rows,
        }, command);
        if (context.observation_stats) |stats| {
            if (submitted) stats.captured += 1 else stats.dropped += 1;
        }
    }

    pub fn finishHistory(pane: *Pane) void {
        if (pane.history_session_finished) return;
        var capture_context: CaptureContext = .{ .pane = pane };
        if (pane.history_observer.enabled)
            pane.history_observer.tracker.interrupt(
                historyClock(pane.io),
                &capture_context,
                captureCommand,
            );
        if (pane.history_session_started) {
            _ = pane.history_service.finishSession(
                pane.io,
                pane.history_session_id,
                Io.Timestamp.now(pane.io, .real).toMilliseconds(),
            );
        }
        pane.history_session_finished = true;
    }

    pub fn queueExitedHistory(pane: *Pane, exit: pty.Exit) void {
        if (pane.history_exit_queued) return;
        pane.history_observer.queueShellExit(historyClock(pane.io), exit.code());
        pane.history_exit_queued = true;
    }

    /// True only when no actor task can still access the pane allocation.
    /// Scheduling owns one count and consuming its `PaneKey` result releases
    /// it, so adding a new actor cannot silently bypass the lifetime proof by
    /// forgetting to extend a list of operation-specific flags.
    pub fn readyToDestroy(pane: *const Pane) bool {
        return pane.exit != null and pane.output_done and
            pane.actor_count == 0 and
            pane.history_observer.worker == null and
            !pane.history_observer.hasPending() and
            pane.media.worker == null and
            !pane.media.hasPending() and
            pane.pty_responses.len == 0;
    }

    pub fn resize(pane: *Pane, size: schema.TerminalSize) !void {
        try pane.requestResize(size);
        try pane.applyPendingResize();
    }

    pub fn requestResize(pane: *Pane, size: schema.TerminalSize) !void {
        if (std.meta.eql(pane.pending_size orelse pane.size, size)) return;
        try pane.session.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        });
        pane.pending_size = size;
    }

    pub fn applyPendingResize(pane: *Pane) !void {
        const size = pane.pending_size orelse return;
        {
            const terminal_allocations = diagnostics.enterTerminalAllocations();
            defer terminal_allocations.restore();
            try pane.stream.handler.resize(.{
                .cols = size.cols,
                .rows = size.rows,
                .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
                    .width = size.cell_width_px,
                    .height = size.cell_height_px,
                } else null,
            });
        }
        pane.observeGraphicsDamage();
        try resizeScreenStorage(pane.gpa, &pane.screen, &pane.damaged_rows, size.cols, size.rows);
        // Committed only after every fallible step: a failure above leaves the
        // pending size in place for a retry and the pane fully coherent.
        pane.size = size;
        pane.pending_size = null;
        pane.history_observer.queueResize(size);
        pane.media.queueResize(size);
        try pane.render(true);
    }

    /// Whether the child is inside a synchronized-output block (DEC private
    /// mode 2026) and its frames must be held. A client of that mode - neovim
    /// is one - repaints without hiding the cursor and relies on the terminal
    /// presenting only the finished screen; a frame emitted mid-block shows
    /// the cursor wherever the repaint happens to be. The deadline matches
    /// ghostty's and exists so a child that never closes the block cannot
    /// freeze its pane.
    pub fn holdFrames(pane: *Pane, io: Io) bool {
        if (!pane.terminal.modes.get(.synchronized_output)) {
            pane.sync_hold_started_ns = null;
            return false;
        }
        const now_ns: u64 = @intCast(@max(Io.Timestamp.now(io, .awake).nanoseconds, 0));
        const started = pane.sync_hold_started_ns orelse {
            pane.sync_hold_started_ns = now_ns;
            return true;
        };
        return now_ns -| started < max_sync_hold_ns;
    }

    pub fn render(pane: *Pane, force: bool) !void {
        {
            const terminal_allocations = diagnostics.enterTerminalAllocations();
            defer terminal_allocations.restore();
            try pane.render_state.update(pane.gpa, &pane.terminal);
        }
        const force_all = force or pane.semantic_colors_dirty;
        _ = blit.blit(
            &pane.screen,
            pane.screen.area(),
            &pane.terminal,
            &pane.render_state,
            .{ .force = force_all, .damaged_rows = pane.damaged_rows },
        );
        pane.semantic_colors_dirty = false;
        pane.render_pending = false;
        pane.cell_revision +%= 1;
        if (pane.cell_revision == 0) pane.cell_revision = 1;
        const cursor = pane.render_state.cursor;
        pane.cursor = if (cursor.visible and cursor.viewport != null and
            cursor.viewport.?.x < pane.screen.w and cursor.viewport.?.y < pane.screen.h)
            .{ .visible = true, .x = cursor.viewport.?.x, .y = cursor.viewport.?.y }
        else
            .{};
        pane.dirty = true;
    }
};

/// Resizes the cell grid and its per-row damage flags together.
///
/// The two lengths are one invariant: `blit` writes `damaged[row]` for every
/// row of the screen, so a screen that grew without its flags is an
/// out-of-bounds write in release builds. Either both carry the new geometry
/// after this returns, or an error left both untouched.
pub fn resizeScreenStorage(
    gpa: std.mem.Allocator,
    screen: *core.ui.Buffer,
    damaged_rows: *[]bool,
    cols: u16,
    rows: u16,
) !void {
    const damaged = try gpa.alloc(bool, rows);
    screen.resize(cols, rows) catch |err| {
        gpa.free(damaged);
        return err;
    };
    @memset(damaged, false);
    gpa.free(damaged_rows.*);
    damaged_rows.* = damaged;
}

/// Fixed-capacity open-addressed map from a raw u64 id to a store slot.
///
/// `find` runs on the interactive path - per keystroke through
/// `attachedPane`, per event through `collectFinished` - where a linear scan
/// of the store was O(pane count) each time. Ids are never zero and never
/// `maxInt`, which the empty and tombstone markers rely on.
pub const SlotIndex = core.fixed_index.SlotIndex;

pub const PaneStore = struct {
    items: [max_panes]?*Pane = [_]?*Pane{null} ** max_panes,
    count: usize = 0,
    /// Panes whose child has exited but which have not been collected yet.
    /// `collectFinished` runs on every event; this makes the common case -
    /// nothing exited - one branch instead of a store scan.
    exited_count: usize = 0,
    index: SlotIndex(2 * max_panes) = .{},
    next_id: u64 = 1,
    next_generation: u64 = 1,
    graphics_limits: GraphicsLimits = .{},
    graphics_budget: GraphicsBudget = .init(core.graphics.max_image_bytes_global),

    pub fn find(store: *PaneStore, pane_id: schema.PaneId) ?*Pane {
        const slot = store.index.get(schema.id.raw(pane_id)) orelse return null;
        const pane = store.items[slot].?;
        std.debug.assert(pane.id == pane_id);
        return pane;
    }

    pub fn findRunning(store: *PaneStore, pane_id: schema.PaneId) ?*Pane {
        const pane = store.find(pane_id) orelse return null;
        return if (pane.launch_state.discoverable()) pane else null;
    }

    pub fn resolve(store: *PaneStore, key: PaneKey) ?*Pane {
        const pane = store.find(key.id) orelse return null;
        if (pane.generation != key.generation) return null;
        return pane;
    }

    pub fn resolveConst(store: *const PaneStore, key: PaneKey) ?*const Pane {
        const slot = store.index.get(schema.id.raw(key.id)) orelse return null;
        const pane = store.items[slot].?;
        std.debug.assert(pane.id == key.id);
        if (pane.generation != key.generation) return null;
        return pane;
    }

    pub fn firstAt(store: *PaneStore, location: schema.TabLocation) ?*Pane {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (pane.launch_state.discoverable() and
                !pane.close_requested and pane.exit == null and
                std.meta.eql(pane.location, location)) return pane;
        }
        return null;
    }

    pub fn descriptorsAt(
        store: *const PaneStore,
        location: schema.TabLocation,
        output: *[max_panes]schema.PaneDescriptor,
    ) []const schema.PaneDescriptor {
        var len: usize = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null or
                !std.meta.eql(pane.location, location)) continue;
            output[len] = .{
                .pane_id = pane.id,
                .lifecycle = .running,
            };
            len += 1;
        }
        return output[0..len];
    }

    pub fn positionAt(store: *const PaneStore, wanted: *const Pane) ?u16 {
        var position: u16 = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null or
                !std.meta.eql(pane.location, wanted.location)) continue;
            position += 1;
            if (pane == wanted) return position;
        }
        return null;
    }

    pub fn countAt(store: *const PaneStore, location: schema.TabLocation) u16 {
        var count: u16 = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (pane.launch_state.discoverable() and
                !pane.close_requested and pane.exit == null and
                std.meta.eql(pane.location, location)) count += 1;
        }
        return count;
    }

    /// Unlike `firstAt`/`countAt`, deliberately counts closing and exited
    /// panes too: `collectFinished` uses it to decide whether a tab is truly
    /// empty, and a pane that is merely not yet reaped still holds its tab.
    pub fn hasAt(store: *const PaneStore, location: schema.TabLocation) bool {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (std.meta.eql(pane.location, location)) return true;
        }
        return false;
    }

    pub fn closeAt(store: *PaneStore, location: schema.TabLocation) void {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!std.meta.eql(pane.location, location)) {
                continue;
            }

            _ = pane.requestClose();
        }
    }

    pub fn allocateKey(store: *PaneStore) !PaneKey {
        if (store.count == max_panes) return error.PaneLimitReached;
        const pane_id = try schema.id.pane(store.next_id);
        if (store.next_generation == 0 or store.next_generation == std.math.maxInt(u64))
            return error.PaneGenerationExhausted;
        const generation = store.next_generation;
        store.next_id += 1;
        store.next_generation += 1;
        return .{ .id = pane_id, .generation = generation };
    }

    pub fn insert(store: *PaneStore, pane: *Pane) !void {
        for (&store.items, 0..) |*slot, position| {
            if (slot.* == null) {
                slot.* = pane;
                store.index.put(schema.id.raw(pane.id), position);
                store.count += 1;
                return;
            }
        }
        return error.PaneLimitReached;
    }

    pub fn removeAndDestroy(store: *PaneStore, pane: *Pane) void {
        for (&store.items) |*slot| {
            if (slot.* == pane) {
                store.index.remove(schema.id.raw(pane.id));
                if (pane.exit != null) store.exited_count -= 1;
                slot.* = null;
                store.count -= 1;
                pane.destroy();
                return;
            }
        }
        unreachable;
    }

    pub fn shutdown(store: *PaneStore) void {
        for (store.items) |slot| if (slot) |pane| pane.session.shutdown();
    }

    pub fn deinit(store: *PaneStore) void {
        for (&store.items) |*slot| {
            if (slot.*) |pane| pane.destroy();
            slot.* = null;
        }
        store.index.reset();
        store.exited_count = 0;
        store.count = 0;
    }
};

pub fn historyClock(io: Io) history.osc.Clock {
    return .{
        .real_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
        .awake_ns = @intCast(Io.Timestamp.now(io, .awake).toNanoseconds()),
    };
}

test "cwd state is bounded and advances only for a new valid path" {
    var state = try CwdState.init("/work/telar");
    try std.testing.expectEqualStrings("/work/telar", state.slice());
    try std.testing.expectEqual(@as(u64, 1), state.revision);
    try std.testing.expect(!state.update("/work/telar"));
    try std.testing.expectEqual(@as(u64, 1), state.revision);

    try std.testing.expect(state.update("/work/agents"));
    try std.testing.expectEqualStrings("/work/agents", state.slice());
    try std.testing.expectEqual(@as(u64, 2), state.revision);

    try std.testing.expect(!state.update(""));
    try std.testing.expect(!state.update("/work\x00hidden"));
    const oversized = [_]u8{'x'} ** (schema.max_cwd_bytes + 1);
    try std.testing.expect(!state.update(&oversized));
    try std.testing.expectEqualStrings("/work/agents", state.slice());
    try std.testing.expectError(error.InvalidCwd, CwdState.init(""));
}

test "pane store rejects an event from another generation" {
    var store: PaneStore = .{};
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    try store.insert(&pane);

    try std.testing.expectEqual(&pane, store.resolve(.{
        .id = pane.id,
        .generation = pane.generation,
    }).?);
    try std.testing.expect(store.resolve(.{
        .id = pane.id,
        .generation = pane.generation + 1,
    }) == null);

    store.index.remove(schema.id.raw(pane.id));
    store.items = @splat(null);
    store.count = 0;
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

test "the slot index survives collisions, removals, and slot reuse" {
    var index: SlotIndex(8) = .{};
    // More keys than buckets divided by two forces probe chains.
    index.put(1, 0);
    index.put(9, 1);
    index.put(17, 2);
    try std.testing.expectEqual(@as(?usize, 0), index.get(1));
    try std.testing.expectEqual(@as(?usize, 1), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));
    try std.testing.expectEqual(@as(?usize, null), index.get(25));

    // A tombstone must not break the probe chain behind it.
    index.remove(9);
    try std.testing.expectEqual(@as(?usize, null), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));

    // And its bucket is reusable.
    index.put(33, 5);
    try std.testing.expectEqual(@as(?usize, 5), index.get(33));

    index.reset();
    try std.testing.expectEqual(@as(?usize, null), index.get(1));
    try std.testing.expectEqual(@as(?usize, null), index.get(17));
}

test "pane launch state settles exactly once" {
    var committed: LaunchState = .starting;
    committed.commit();
    try std.testing.expectEqual(LaunchState.running, committed);
    try std.testing.expect(committed.discoverable());

    var aborted: LaunchState = .starting;
    aborted.abort();
    try std.testing.expectEqual(LaunchState.aborting, aborted);
    try std.testing.expect(!aborted.discoverable());
}

test "PaneStore discovers only committed launches" {
    const pane_id = try schema.id.pane(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    var pane: Pane = undefined;
    pane.id = pane_id;
    pane.generation = 1;
    pane.location = location;
    pane.launch_state = .starting;
    pane.close_requested = false;
    pane.exit = null;

    var store: PaneStore = .{};
    try store.insert(&pane);
    try std.testing.expect(store.find(pane_id) == &pane);
    try std.testing.expect(store.findRunning(pane_id) == null);
    try std.testing.expect(store.firstAt(location) == null);
    try std.testing.expectEqual(@as(u16, 0), store.countAt(location));
    try std.testing.expect(store.hasAt(location));

    pane.launch_state.commit();
    try std.testing.expect(store.findRunning(pane_id) == &pane);
    try std.testing.expect(store.firstAt(location) == &pane);
    try std.testing.expectEqual(@as(u16, 1), store.countAt(location));
}

test "pane creation releases every partial allocation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, ":memory:");
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{"/bin/true"};
    const command = try pty.Command.fromArgv(&argv);
    const limits: GraphicsLimits = .{};
    var fail_index: usize = 0;
    var completed = false;
    while (!completed) : (fail_index += 1) {
        try std.testing.expect(fail_index < 256);
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var budget = GraphicsBudget.init(limits.global_bytes);
        const result = Pane.create(
            io,
            failing.allocator(),
            .{ .id = @enumFromInt(1), .generation = 1 },
            .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(1),
            },
            &command,
            "/work/telar",
            "/work/telar",
            &history_service,
            .{ .cols = 20, .rows = 5 },
            limits,
            &budget,
        );
        if (result) |pane| {
            pane.abortLaunch();
            pane.destroy();
            completed = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(@as(usize, 0), budget.used);
    }
}

test "pane keeps launch cwd separate from workspace path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, ":memory:");
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = @enumFromInt(1), .generation = 1 },
        .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        &command,
        "/",
        "/work/telar",
        &history_service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
    defer {
        pane.session.shutdown();
        pane.destroy();
    }
    try std.testing.expectEqualStrings("/", pane.cwd.slice());
    try std.testing.expectEqualStrings("/work/telar", pane.workspace_path);
}

test "pane close requests shut down the PTY exactly once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, ":memory:");
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(
        io,
        gpa,
        .{ .id = @enumFromInt(1), .generation = 1 },
        .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        &command,
        "/",
        "/work/telar",
        &history_service,
        .{ .cols = 20, .rows = 5 },
        .{},
        &budget,
    );
    defer pane.destroy();

    try std.testing.expect(pane.requestClose());
    try std.testing.expect(!pane.requestClose());
    try std.testing.expect(pane.close_requested);
}

test "a pane is destroyable only when no actor can still borrow it" {
    var pane: Pane = undefined;
    pane.exit = .{ .exited = 0 };
    pane.output_done = true;
    pane.actor_count = 0;
    pane.pty_responses = .{};
    pane.history_observer.active = 0;
    pane.history_observer.worker = null;
    pane.history_observer.batches = .{ .{}, .{} };
    pane.media.active = 0;
    pane.media.worker = null;
    pane.media.batches = .{ .{}, .{} };
    try std.testing.expect(pane.readyToDestroy());

    pane.actorStarted();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorStarted();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorFinished();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorFinished();
    try std.testing.expect(pane.readyToDestroy());
    _ = pane.pty_responses.push("late reply");
    try std.testing.expect(!pane.readyToDestroy());
    pane.pty_responses.clear();
    pane.exit = null;
    try std.testing.expect(!pane.readyToDestroy());
}

test "a child's synchronized-output block holds frames until it closes or expires" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(io, gpa, .{ .cols = 10, .rows = 4 });
    defer pane.terminal.deinit(gpa);
    pane.sync_hold_started_ns = null;

    // No block: frames flow and no hold is recorded.
    try std.testing.expect(!pane.holdFrames(io));
    try std.testing.expectEqual(@as(?u64, null), pane.sync_hold_started_ns);

    // Inside the block frames are held, against one stable deadline.
    pane.terminal.modes.set(.synchronized_output, true);
    try std.testing.expect(pane.holdFrames(io));
    const started = pane.sync_hold_started_ns.?;
    try std.testing.expect(pane.holdFrames(io));
    try std.testing.expectEqual(started, pane.sync_hold_started_ns.?);

    // A block the child never closes expires instead of freezing the pane.
    pane.sync_hold_started_ns = started -| max_sync_hold_ns;
    try std.testing.expect(!pane.holdFrames(io));

    // Closing the block releases the hold and forgets the deadline.
    pane.sync_hold_started_ns = started;
    pane.terminal.modes.set(.synchronized_output, false);
    try std.testing.expect(!pane.holdFrames(io));
    try std.testing.expectEqual(@as(?u64, null), pane.sync_hold_started_ns);
}

test "pane input modes expose child focus reporting" {
    const gpa = std.testing.allocator;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 2, .rows = 1 });
    defer pane.terminal.deinit(gpa);

    try std.testing.expect(!pane.inputModeState().focus_events);
    pane.terminal.modes.set(.focus_event, true);
    try std.testing.expect(pane.inputModeState().focus_events);
}

test "pane keyboard modes follow VT negotiation and screen-local stacks" {
    const gpa = std.testing.allocator;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 2, .rows = 1 });
    defer pane.terminal.deinit(gpa);
    var stream = pane.terminal.vtStream();
    defer stream.deinit();

    const steps = [_]struct { sequence: []const u8, flags: u5, modify_other_keys: bool = false }{
        .{ .sequence = "\x1b[>1u", .flags = 1 },
        .{ .sequence = "\x1b[>5u", .flags = 5 },
        .{ .sequence = "\x1b[<u", .flags = 1 },
        .{ .sequence = "\x1b[?1049h", .flags = 0 },
        .{ .sequence = "\x1b[>8u", .flags = 8 },
        .{ .sequence = "\x1b[?1049l", .flags = 1 },
        .{ .sequence = "\x1b[<u", .flags = 0 },
        .{ .sequence = "\x1b[>4;2m", .flags = 0, .modify_other_keys = true },
        .{ .sequence = "\x1b[>4;0m", .flags = 0 },
    };
    for (steps) |step| {
        // VT parsing must retain a control sequence across arbitrary PTY reads.
        for (step.sequence) |byte| stream.nextSlice(&.{byte});
        const modes = pane.inputModeState();
        try std.testing.expectEqual(step.flags, modes.kitty_keyboard_flags);
        try std.testing.expectEqual(step.modify_other_keys, modes.modify_other_keys_2);
    }
}

test "a failed resize cannot split the screen from its damage flags" {
    const gpa = std.testing.allocator;
    var fail_index: usize = 0;
    var completed = false;
    while (!completed) : (fail_index += 1) {
        try std.testing.expect(fail_index < 64);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var screen = core.ui.Buffer.init(allocator, 10, 4) catch continue;
        defer screen.deinit();
        var damaged = allocator.alloc(bool, 4) catch continue;
        defer allocator.free(damaged);
        const result = resizeScreenStorage(allocator, &screen, &damaged, 20, 9);
        // The invariant `blit` depends on, success and failure alike.
        try std.testing.expectEqual(@as(usize, screen.h), damaged.len);
        if (result) |_| {
            completed = true;
        } else |_| {}
    }
}

test "the PTY response queue bounds depth and entry size" {
    var queue: PtyResponseQueue = .{};
    try std.testing.expect(queue.push("first"));
    try std.testing.expect(queue.push("second"));
    try std.testing.expectEqualStrings("first", queue.peek().?);
    queue.pop();
    try std.testing.expectEqualStrings("second", queue.peek().?);

    const oversized = [_]u8{'x'} ** (max_pty_response_bytes + 1);
    try std.testing.expect(!queue.push(&oversized));
    try std.testing.expectEqual(@as(u64, 1), queue.dropped);

    while (queue.len < max_pty_responses) _ = queue.push("fill");
    try std.testing.expect(!queue.push("overflow"));
    try std.testing.expectEqual(@as(u64, 2), queue.dropped);
    queue.clear();
    try std.testing.expectEqual(@as(u8, 0), queue.len);
    try std.testing.expect(queue.peek() == null);
}

test "the pane input queue reports whole-message loss" {
    var queue: PaneInputQueue = .{};
    const first = [_]u8{'a'} ** schema.max_input_bytes;
    const second = [_]u8{'b'} ** schema.max_input_bytes;
    try std.testing.expect(queue.push(&first));
    try std.testing.expect(queue.push(&second));
    try std.testing.expect(!queue.push("lost"));
    try std.testing.expectEqual(@as(u64, 4), queue.dropped_bytes);
    try std.testing.expectEqual(@as(usize, PaneInputQueue.capacity), queue.len);

    queue.consume(schema.max_input_bytes);
    try std.testing.expect(queue.push("kept"));
    try std.testing.expectEqualStrings(second[0..], queue.nextChunk().?);
}
