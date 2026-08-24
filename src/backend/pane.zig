//! One runtime pane: its process, PTY, emulator, buffers, and quotas.
//!
//! Split out of `runtime.zig`; ownership rules are unchanged. The runtime
//! event loop drives these panes through `PaneStore`, and actor threads
//! borrow `*Pane` only under the pending flags that `readyToDestroy` checks.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const blit = @import("blit.zig");
const escape = @import("history/escape.zig");
const history = @import("history/root.zig");
const pty = @import("pty.zig");
const telemetry = @import("telemetry.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const RuntimeMetrics = telemetry.RuntimeMetrics;

pub const max_panes = schema.max_panes_per_tab;

pub const output_chunk_size = 16 * 1024;

pub const max_pty_response_bytes = 1024;

pub const max_pty_responses = 64;

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
    history_input_bytes: u64 = 0,
    history_captured: u64 = 0,
    history_dropped: u64 = 0,
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

pub const KittyFramingCounter = escape.KittyFramingCounter;

pub const HistoryInputBatch = struct {
    pub const max_entries = 256;
    pub const Entry = struct {
        offset: u32,
        len: u32,
        shell_foreground: bool,
        clock: history.Clock,
    };

    bytes: [schema.max_input_bytes]u8 = undefined,
    len: usize = 0,
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,

    pub fn reset(batch: *HistoryInputBatch) void {
        batch.len = 0;
        batch.entry_count = 0;
    }

    pub fn push(
        batch: *HistoryInputBatch,
        bytes: []const u8,
        shell_foreground: bool,
        clock: history.Clock,
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
        return true;
    }
};

pub const Pane = struct {
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
    input_queue: PaneInputQueue = .{},
    input_write_pending: bool = false,
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

    pub fn create(
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

        const workspace_copy = try gpa.dupe(u8, workspace_path);
        errdefer gpa.free(workspace_copy);
        var session: pty.Session = try .spawn(command, .{
            .cols = size.cols,
            .rows = size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        });
        errdefer session.deinit();

        // `gpa.create` returns undefined memory, so declared defaults do not
        // apply on their own; the struct literal makes the compiler enforce
        // that every remaining field is either defaulted or listed here. The
        // handler-bearing fields stay `undefined` until the pane has its
        // final address, because the VT handler captures `&pane.terminal`.
        pane.* = .{
            .id = id,
            .location = location,
            .io = io,
            .gpa = gpa,
            .history_service = history_service,
            .graphics_limits = graphics_limits,
            .graphics_storage_limit = graphics_limits.pane_bytes / 3,
            .media_allocator = .init(gpa, graphics_budget, graphics_limits.pane_bytes),
            .history_session_id = history_service.newSessionId(io),
            .workspace_path = workspace_copy,
            .session = session,
            .size = size,
            .terminal = undefined,
            .stream = undefined,
            .history_tracker = undefined,
            .screen = undefined,
            .damaged_rows = undefined,
        };
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

    pub fn inputModeState(pane: *const Pane) schema.frame.InputModes {
        const modes = &pane.terminal.modes;
        return .{
            .cursor_keys = modes.get(.cursor_keys),
            .keypad_keys = modes.get(.keypad_keys),
            .bracketed_paste = modes.get(.bracketed_paste),
        };
    }

    pub fn destroy(pane: *Pane) void {
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

    pub fn ingest(pane: *Pane, io: Io, bytes: []const u8, stats: *PaneIngestStats) !u64 {
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
        pane.input_modes = pane.inputModeState();
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

    pub fn queueHistoryInput(
        pane: *Pane,
        bytes: []const u8,
        shell_foreground: bool,
        clock: history.Clock,
    ) void {
        const batch = &pane.history_input_batches[pane.history_input_active];
        if (!batch.push(bytes, shell_foreground, clock))
            pane.history_input_dropped +|= 1;
    }

    pub fn sealHistoryInput(pane: *Pane) void {
        std.debug.assert(pane.history_input_worker == null);
        const sealed = pane.history_input_active;
        pane.history_input_active ^= 1;
        std.debug.assert(pane.history_input_batches[pane.history_input_active].entry_count == 0);
        pane.history_input_worker = sealed;
    }

    pub fn processHistoryInput(pane: *Pane, stats: *PaneIngestStats) u64 {
        const index = pane.history_input_worker orelse return 0;
        const batch = &pane.history_input_batches[index];
        if (batch.entry_count != 0) {
            // The cwd probe is a process-inspection syscall; it belongs on
            // this observation worker, once per input batch, never in the
            // per-keystroke dispatch path.
            var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (pane.session.cwd(&cwd_buffer)) |cwd|
                pane.history_tracker.updateCwd(cwd);
        }
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

    pub fn enforceIncompleteGraphics(
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
        const storage = &pane.terminal.screens.active.kitty_images;
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
        metrics: ?*RuntimeMetrics = null,
        ingest_stats: ?*PaneIngestStats = null,
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

    pub fn finishHistory(pane: *Pane) void {
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

    pub fn finishExitedHistory(pane: *Pane, exit: pty.Exit, metrics: *RuntimeMetrics) void {
        var capture_context: CaptureContext = .{ .pane = pane, .metrics = metrics };
        pane.history_tracker.shellExited(
            historyClock(pane.io),
            exit.code(),
            &capture_context,
            captureCommand,
        );
    }

    /// True only when no actor thread can still hold this pane. Actors borrow
    /// `*Pane` rather than an ID, so every destroy site must consult this
    /// predicate; destroying past a pending flag is a use-after-free.
    pub fn readyToDestroy(pane: *const Pane) bool {
        return pane.exit != null and pane.output_done and
            !pane.output_pending and !pane.ingest_pending and
            !pane.wait_pending and !pane.response_pending and
            !pane.input_write_pending and
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
        try pane.stream.handler.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
                .width = size.cell_width_px,
                .height = size.cell_height_px,
            } else null,
        });
        pane.observeGraphicsDamage();
        try resizeScreenStorage(pane.gpa, &pane.screen, &pane.damaged_rows, size.cols, size.rows);
        // Committed only after every fallible step: a failure above leaves the
        // pending size in place for a retry and the pane fully coherent.
        pane.size = size;
        pane.pending_size = null;
        try pane.render(true);
    }

    pub fn render(pane: *Pane, force: bool) !void {
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
pub fn SlotIndex(comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        pub const Self = @This();
        pub const empty_key: u64 = 0;
        pub const tombstone_key: u64 = std.math.maxInt(u64);

        keys: [capacity]u64 = @splat(empty_key),
        slots: [capacity]u8 = undefined,

        pub fn put(index: *Self, key: u64, slot: usize) void {
            std.debug.assert(key != empty_key and key != tombstone_key);
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                switch (index.keys[probe]) {
                    empty_key, tombstone_key => {
                        index.keys[probe] = key;
                        index.slots[probe] = @intCast(slot);
                        return;
                    },
                    else => std.debug.assert(index.keys[probe] != key),
                }
            }
        }

        pub fn get(index: *const Self, key: u64) ?usize {
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                const found = index.keys[probe];
                if (found == key) return index.slots[probe];
                if (found == empty_key) return null;
            }
        }

        pub fn remove(index: *Self, key: u64) void {
            var probe = std.hash.int(key) % capacity;
            while (true) : (probe = (probe + 1) % capacity) {
                const found = index.keys[probe];
                if (found == key) {
                    index.keys[probe] = tombstone_key;
                    return;
                }
                if (found == empty_key) return;
            }
        }

        pub fn reset(index: *Self) void {
            index.keys = @splat(empty_key);
        }
    };
}

pub const PaneStore = struct {
    items: [max_panes]?*Pane = [_]?*Pane{null} ** max_panes,
    count: usize = 0,
    /// Panes whose child has exited but which have not been collected yet.
    /// `collectFinished` runs on every event; this makes the common case -
    /// nothing exited - one branch instead of a store scan.
    exited_count: usize = 0,
    index: SlotIndex(2 * max_panes) = .{},
    next_id: u64 = 1,
    graphics_limits: GraphicsLimits = .{},
    graphics_budget: GraphicsBudget = .init(core.graphics.max_image_bytes_global),

    pub fn find(store: *PaneStore, pane_id: schema.PaneId) ?*Pane {
        const slot = store.index.get(schema.id.raw(pane_id)) orelse return null;
        const pane = store.items[slot].?;
        std.debug.assert(pane.id == pane_id);
        return pane;
    }

    pub fn firstAt(store: *PaneStore, location: schema.TabLocation) ?*Pane {
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.close_requested and pane.exit == null and
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

    pub fn countAt(store: *const PaneStore, location: schema.TabLocation) u16 {
        var count: u16 = 0;
        for (store.items) |slot| {
            const pane = slot orelse continue;
            if (!pane.close_requested and pane.exit == null and
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
            if (!std.meta.eql(pane.location, location) or pane.close_requested) continue;
            pane.close_requested = true;
            pane.session.shutdown();
        }
    }

    pub fn allocateId(store: *PaneStore) !schema.PaneId {
        if (store.count == max_panes) return error.PaneLimitReached;
        const pane_id = try schema.id.pane(store.next_id);
        store.next_id += 1;
        return pane_id;
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

test "a pane is destroyable only when no actor can still borrow it" {
    var pane: Pane = undefined;
    pane.exit = .{ .exited = 0 };
    pane.output_done = true;
    pane.output_pending = false;
    pane.ingest_pending = false;
    pane.wait_pending = false;
    pane.response_pending = false;
    pane.pty_responses = .{};
    try std.testing.expect(pane.readyToDestroy());

    // Each pending flag marks an actor thread that still holds `*Pane`.
    pane.response_pending = true;
    try std.testing.expect(!pane.readyToDestroy());
    pane.response_pending = false;
    pane.wait_pending = true;
    try std.testing.expect(!pane.readyToDestroy());
    pane.wait_pending = false;
    pane.ingest_pending = true;
    try std.testing.expect(!pane.readyToDestroy());
    pane.ingest_pending = false;
    pane.output_pending = true;
    try std.testing.expect(!pane.readyToDestroy());
    pane.output_pending = false;
    _ = pane.pty_responses.push("late reply");
    try std.testing.expect(!pane.readyToDestroy());
    pane.pty_responses.clear();
    pane.exit = null;
    try std.testing.expect(!pane.readyToDestroy());
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
