const vtgrid = @import("vtgrid");
const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const revisions = @import("../revisions.zig");
const pty = @import("pty");
const Session = pty.Session;
const core = @import("telar-core");
const pane_namespace = @import("pane_namespace.zig");
const vt = @import("ghostty-vt");
const Pipeline = @import("../media/Pipeline.zig");
const PtyResponseQueue = @import("PtyResponseQueue.zig");
const GraphicsLimits = @import("../media/GraphicsLimits.zig");
const PaneMediaAllocator = @import("../media/PaneMediaAllocator.zig");
const std = @import("std");
const PaneInputQueue = @import("PaneInputQueue.zig");
const State = @import("../media/State.zig");
const exit_module = pty.exit;
const Service = @import("../history/Service.zig");
const Observer = @import("../history/Observer.zig");
const Cache = @import("../process/Cache.zig");
const model = @import("../history/model.zig");
const Sequence = @import("../history/Sequence.zig");
const CwdState = @import("CwdState.zig");
const TitleState = @import("TitleState.zig");
const LaunchRecord = @import("LaunchRecord.zig");
const TextRequest = @import("TextRequest.zig");
const TextDump = @import("TextDump.zig");
const SearchResult = @import("SearchResult.zig");
const text_search = @import("text_search.zig");
const PaneCursor = text_search.Search;
const PaneKey = @import("PaneKey.zig");
const MediaProcessingBorrow = @import("MediaProcessingBorrow.zig");
const Stats = @import("../media/Stats.zig");
const Processor = @import("../media/Processor.zig");
const ObserverInputObservation = @import("../history/ObserverInputObservation.zig");
const ObserverOutputObservation = @import("../history/ObserverOutputObservation.zig");
const HistoryObservationBorrow = @import("HistoryObservationBorrow.zig");
const HistoryObservationCompletion = @import("HistoryObservationCompletion.zig");
const agent_process = @import("../process/process.zig");
const HistoryStats = @import("../history/Stats.zig");
const cwd_module = @import("../process/cwd.zig");
const ReviewAvailability = @import("../change_review/Availability.zig");
pub const Pane = @This();

pub const CreationResources = @import("CreationResources.zig");

pub const CreationRequest = @import("CreationRequest.zig");

id: core.PaneId,
generation: u64,
location: core.TabLocation,
launch_state: pane_namespace.LaunchState = .starting,
session: Session,
review_availability: ReviewAvailability = .{},
/// One bit per client slot that holds an attachment to this pane. Delivery,
/// damage settling and collection visit only these clients.
observers: u8 = 0,
terminal: vt.Terminal,
stream: vt.TerminalStream,
media: Pipeline,
pty_responses: PtyResponseQueue = .{},
graphics_limits: GraphicsLimits,
graphics_storage_limit: usize,
media_allocator: PaneMediaAllocator,
pty_write_mutex: std.Io.Mutex = .init,
response_pending: bool = false,
input_queue: PaneInputQueue = .{},
/// Last admitted input; each attachment independently grants prompt echo frames.
cell_input_ns: ?u64 = null,
input_write_pending: bool = false,
input_write_len: usize = 0,
size: core.TerminalSize,
render_state: vt.RenderState = .empty,
text_metadata: TextMetadataCapture,
screen: cellgrid.Buffer,
damaged_rows: []bool,
output_buffer: [pane_namespace.output_chunk_size]u8 = undefined,
cursor: core.Cursor = .{},
mouse: core.Mouse = .{},
input_modes: keyinput.InputModes = .{},
pointer_shape: core.PointerShape = .default,
foreground_override: ?vt.color.RGB = null,
background_override: ?vt.color.RGB = null,
semantic_colors_dirty: bool = false,
graphics_revision: u64 = 0,
graphics_present: bool = false,
media_ingestion: State = .{},
dirty: bool = true,
render_pending: bool = true,
cell_revision: u64 = 1,
search_revision: u64 = 1,
output_pending: bool = false,
ingest_pending: bool = false,
actor_count: u8 = 0,
output_done: bool = false,
wait_pending: bool = false,
close_requested: bool = false,
exit: ?exit_module.Exit = null,
history_service: *Service,
history_observer: Observer,
agent_process_cache: Cache = .{},
foreground_revision: u64 = 1,
progress_state: core.PaneProgressState = .remove,
progress_percent: ?u8 = null,
progress_revision: u64 = 1,
history_session_id: model.SessionId,
started_at_ms: i64,
history_sequence: Sequence = .{},
/// Command submissions injected through the control API or a session
/// restore that have not completed yet. Written by the runtime thread,
/// consumed by the observation actor when the next command finishes.
injected_submissions: std.atomic.Value(u32) = .init(0),
history_session_started: bool = false,
history_session_finished: bool = false,
history_exit_queued: bool = false,
workspace_path: []u8,
cwd: CwdState,
title: TitleState = .{},
launch_record: LaunchRecord = .{},
manifests: *const core.Table,
pending_size: ?core.TerminalSize = null,
pending_terminal_colors: ?core.TerminalColors = null,
/// When the child's synchronized-output block started holding frames
/// back, null while no hold is active. See `holdFrames`.
sync_hold_started_ns: ?u64 = null,
io: std.Io,
gpa: std.mem.Allocator,

/// Allocates and initializes one pane, spawning the child only after every
/// fallible runtime resource has been established.
///
/// ```zig
/// const pane = try Pane.create(resources, request);
/// ```
pub fn create(resources: CreationResources, request: CreationRequest) !*Pane {
    const io = resources.io;
    const gpa = resources.gpa;
    const history_service = resources.history_service;
    const graphics_budget = resources.graphics_budget;
    const identity = request.identity;
    const location = request.location;
    const command = request.command;
    const launch_cwd = request.launch_cwd;
    const workspace_path = request.workspace_path;
    const size = request.size;
    const graphics_limits = request.graphics_limits;

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
        .manifests = resources.manifests,
        .session = undefined,
        .size = size,
        .terminal = undefined,
        .stream = undefined,
        .media = undefined,
        .history_observer = undefined,
        .agent_process_cache = .init(std.mem.span(command.file)),
        .screen = undefined,
        .text_metadata = undefined,
        .damaged_rows = undefined,
    };
    pane.terminal = try .init(io, gpa, .{
        .default_cursor_blink = true,
        .cols = size.cols,
        .rows = size.rows,
        .max_scrollback_bytes = pane_namespace.default_scrollback_bytes,
        .kitty_image_storage_limit = 0,
        .kitty_image_loading_limits = .direct,
    });
    errdefer pane.terminal.deinit(gpa);
    pane.setTerminalColors(request.terminal_colors);
    errdefer pane.render_state.deinit(gpa);
    var handler = pane.terminal.vtHandler();
    handler.apc_handler.enable(.kitty, false);
    handler.effects.write_pty = writePty;
    handler.effects.size = reportSize;
    handler.effects.progress_report = reportProgress;
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
    try pane.media.init(.{
        .io = io,
        .allocator = pane.media_allocator.allocator(),
        .size = size,
        .storage_limit = @min(core.max_image_bytes_per_screen, graphics_limits.pane_bytes / 2),
        .payload_limit = graphics_limits.payload_bytes,
        .write_pty = writeMediaPty,
    });
    errdefer pane.media.deinit();
    try pane.history_observer.init(.{
        .io = io,
        .gpa = gpa,
        .cwd = launch_cwd,
        .size = size,
        .manifests = resources.manifests,
        .capture_output = resources.history_service.capturesOutput(),
    });
    errdefer pane.history_observer.deinit();
    pane.text_metadata = try .init(gpa, size.rows);
    errdefer pane.text_metadata.deinit(gpa);
    pane.screen = try .init(gpa, size.cols, size.rows);
    errdefer pane.screen.deinit();
    pane.damaged_rows = try gpa.alloc(bool, size.rows);
    errdefer gpa.free(pane.damaged_rows);
    @memset(pane.damaged_rows, false);
    pane.foreground_override = pane.terminal.colors.foreground.override;
    pane.background_override = pane.terminal.colors.background.override;
    pane.mouse = pane.mouseState();
    pane.input_modes = pane.inputModeState();
    pane.pointer_shape = pane.pointerShape();
    try pane.render(true);

    // Spawn last. Once the child exists, Pane.create cannot fail and
    // erase evidence that a process ran before launch commit.
    pane.session = try Session.spawn(command, .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_width_px = size.cell_width_px,
        .cell_height_px = size.cell_height_px,
    });
    pane.started_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return pane;
}

pub fn commitLaunch(self: *Pane, shell: []const u8) void {
    self.launch_state.commit();
    self.history_session_started = self.history_service.startSession(self.io, .{
        .session_id = self.history_session_id,
        .pane_id = self.id,
        .location = self.location,
        .workspace_path = self.workspace_path,
        .shell = shell,
        .started_at_ms = self.started_at_ms,
    });
}

pub fn abortLaunch(self: *Pane) void {
    self.launch_state.abort();
    _ = self.requestClose();
}

/// Requests PTY shutdown exactly once. Pane retirement remains owned by
/// the later exit event and actor-drain lifecycle.
///
/// ```zig
/// const started = pane.requestClose();
/// ```
pub fn requestClose(self: *Pane) bool {
    if (self.close_requested) {
        return false;
    }

    self.close_requested = true;
    self.session.shutdown();
    return true;
}

pub fn mouseState(self: *const Pane) core.Mouse {
    const modes = &self.terminal.modes;
    const tracking: keyinput.MouseTracking = if (modes.get(.mouse_event_any))
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

/// Copies visible or recent rows as plain text, newest rows last. Output
/// is bounded by `storage`; when older rows do not fit the dump keeps the
/// prefix and reports truncation. No styling or escape bytes are emitted.
///
/// ```zig
/// var storage: [schema.max_pane_text_bytes]u8 = undefined;
/// const dump = pane.dumpText(.{ .rows = 40, .source = .recent }, &storage);
/// const text = storage[0..dump.len];
/// ```
pub fn dumpText(self: *const Pane, request: TextRequest, storage: []u8) TextDump {
    const screen: *const vt.Screen = self.terminal.screens.active;
    const pages = &screen.pages;
    const total: usize = switch (request.source) {
        .screen => pages.rows,
        .recent => pages.total_rows,
    };
    const wanted = @min(@as(usize, request.rows), total);
    if (wanted == 0) {
        return .{ .len = 0, .truncated = false };
    }

    const start_y: u32 = @intCast(total - wanted);
    const top_left = pages.pin(switch (request.source) {
        .screen => .{ .active = .{ .x = 0, .y = start_y } },
        .recent => .{ .screen = .{ .x = 0, .y = start_y } },
    }) orelse return .{ .len = 0, .truncated = false };
    const bottom_right = pages.getBottomRight(switch (request.source) {
        .screen => .active,
        .recent => .screen,
    }) orelse return .{ .len = 0, .truncated = false };

    var writer = std.Io.Writer.fixed(storage);
    var truncated = false;
    screen.dumpString(&writer, .{ .tl = top_left, .br = bottom_right, .unwrap = false }) catch {
        truncated = true;
    };

    return .{ .len = writer.end, .truncated = truncated };
}

/// Finds `needle` in the most recent rows of scrollback and screen, in
/// document order and absolute coordinates. ASCII case folds unless the
/// needle contains an uppercase letter. Bounded by `max_search_rows`
/// rows, `max_search_cols` cells per row and `storage.len` matches;
/// exceeding any bound sets `truncated`.
///
/// ```zig
/// var matches: [schema.max_search_matches]schema.SearchMatch = undefined;
/// const result = pane.searchText("error", &matches);
/// ```
pub fn searchText(self: *const Pane, needle: []const u8, storage: []core.SearchMatch) SearchResult {
    std.debug.assert(!self.ingest_pending);
    var cursor = PaneCursor.init(needle);
    while (!(cursor.advance(self) catch unreachable)) {}
    const count = @min(storage.len, cursor.count);
    @memcpy(storage[0..count], cursor.matches[0..count]);
    return .{ .count = @intCast(count), .truncated = cursor.truncated or cursor.count > count };
}

pub fn key(self: *const Pane) PaneKey {
    return .{ .id = self.id, .generation = self.generation };
}

/// Ghostty's page allocator size: the same counter `max_scrollback_bytes`
/// prunes against, covering the active grid plus retained history.
///
/// ```zig
/// const retained_bytes = pane.vtScrollbackBytes();
/// ```
pub fn vtScrollbackBytes(self: *const Pane) usize {
    var total: usize = 0;
    for (std.enums.values(vt.ScreenSet.Key)) |screen_key| {
        const screen = self.terminal.screens.get(screen_key) orelse continue;
        total += screen.pages.page_size;
    }
    return total;
}

pub fn vtScreenBytes(self: *const Pane) usize {
    return self.screen.cells.len * @sizeOf(cellgrid.Cell);
}

pub fn actorStarted(self: *Pane) void {
    std.debug.assert(self.actor_count < 8);
    self.actor_count += 1;
}

pub fn actorFinished(self: *Pane) void {
    std.debug.assert(self.actor_count != 0);
    self.actor_count -= 1;
}

/// Borrows the pane allocation until its child-wait actor completes.
///
/// ```zig
/// if (!pane.beginExitWait()) {
///     return;
/// }
/// ```
pub fn beginExitWait(self: *Pane) bool {
    if (self.wait_pending or self.exit != null) {
        return false;
    }

    self.wait_pending = true;
    self.actorStarted();
    return true;
}

/// Rolls back a child-wait actor that could not be scheduled.
///
/// ```zig
/// pane.cancelExitWait();
/// ```
pub fn cancelExitWait(self: *Pane) void {
    std.debug.assert(self.wait_pending);

    self.wait_pending = false;
    self.actorFinished();
}

pub fn completeExitWait(self: *Pane, exit: exit_module.Exit) void {
    std.debug.assert(self.wait_pending);

    self.wait_pending = false;
    self.exit = exit;
    self.actorFinished();
}

pub fn pointerShape(self: *const Pane) core.PointerShape {
    return switch (self.terminal.mouse_shape) {
        inline else => |shape| @field(core.PointerShape, @tagName(shape)),
    };
}

pub fn inputModeState(self: *const Pane) keyinput.InputModes {
    const modes = &self.terminal.modes;
    return .{
        .cursor_keys = modes.get(.cursor_keys),
        .keypad_keys = modes.get(.keypad_keys),
        .bracketed_paste = modes.get(.bracketed_paste),
        .focus_events = modes.get(.focus_event),
        .alternate_scroll = modes.get(.mouse_alternate_scroll),
        .alternate_screen = self.terminal.screens.active_key == .alternate,
        .kitty_keyboard_flags = self.terminal.screens.active.kitty_keyboard.current().int(),
        .modify_other_keys_2 = self.terminal.flags.modify_other_keys_2,
    };
}

pub fn destroy(self: *Pane) void {
    const gpa = self.gpa;
    self.finishHistory();
    gpa.free(self.workspace_path);
    gpa.free(self.damaged_rows);
    self.text_metadata.deinit(gpa);
    self.screen.deinit();
    self.render_state.deinit(gpa);
    self.history_observer.deinit();
    self.media_ingestion.prepared_transfers.discardAll(&self.media_allocator);
    self.media_ingestion.transfer_preparation.deinit(&self.media_allocator);
    self.media.deinit();
    self.stream.deinit();
    self.media_allocator.detach();
    self.terminal.deinit(gpa);
    self.session.deinit();
    gpa.destroy(self);
}

/// Admits at most 32 ASCII cells on the cursor's resident row. No parser
/// continuation, wrapping, style migration, hyperlink or grapheme cleanup
/// can enter this path. Ghostty still performs the actual interpretation.
/// Call only while holding the VT borrow, before starting its actor.
/// Example: `if (pane.canInlineOutput(bytes)) { finishIngestInline(); }`.
pub fn canInlineOutput(self: *const Pane, bytes: []const u8) bool {
    std.debug.assert(self.ingest_pending);

    if (bytes.len == 0 or bytes.len > 32 or !self.stream.ground()) {
        return false;
    }

    const terminal = &self.terminal;
    const screen = terminal.screens.active;
    const cursor = &screen.cursor;

    if (terminal.status_display != .main or terminal.modes.get(.insert) or
        !terminal.modes.get(.wraparound) or cursor.pending_wrap or cursor.hyperlink_id != 0 or
        screen.charset.single_shift != null or @as(usize, cursor.x) + bytes.len > terminal.scrolling_region.right)
    {
        return false;
    }

    switch (screen.charset.charsets.get(screen.charset.gl)) {
        .ascii, .utf8 => {},
        else => return false,
    }

    const cells: [*]const vt.Cell = @ptrCast(cursor.page_cell);

    for (bytes, cells[0..bytes.len]) |byte, cell| {
        if (byte < 0x20 or byte > 0x7e or cell.content_tag != .codepoint or
            cell.wide != .narrow or cell.hyperlink or cell.style_id != cursor.style_id)
        {
            return false;
        }
    }

    return true;
}

pub fn ingest(self: *Pane, io: std.Io, bytes: []const u8) !u64 {
    self.search_revision +%= 1;
    const started = core.now(io);
    {
        const terminal_allocations = core.enterTerminalAllocations();
        defer terminal_allocations.restore();
        self.stream.nextSlice(bytes);
    }
    const foreground = self.terminal.colors.foreground.override;
    const background = self.terminal.colors.background.override;
    self.mouse = self.mouseState();
    self.input_modes = self.inputModeState();
    self.pointer_shape = self.pointerShape();
    _ = self.title.observe(self.terminal.getTitle() orelse "");
    if (!std.meta.eql(self.foreground_override, foreground) or
        !std.meta.eql(self.background_override, background))
    {
        self.foreground_override = foreground;
        self.background_override = background;
        self.semantic_colors_dirty = true;
    }
    self.render_pending = true;
    self.dirty = true;
    return core.elapsed(started, core.now(io));
}

pub fn queueMediaOutput(self: *Pane, bytes: []const u8) void {
    self.media.queueOutput(bytes);
}

/// Seals pending graphics work and borrows the pane allocation for one
/// media actor. Empty pipelines return null without changing state.
///
/// ```zig
/// const media = pane.beginMediaProcessing() orelse return;
/// ```
pub fn beginMediaProcessing(self: *Pane) ?MediaProcessingBorrow {
    if (!self.media.seal()) {
        return null;
    }

    self.actorStarted();
    return .{ .current_size = self.size };
}

/// Releases one completed media actor and its sealed batch.
///
/// ```zig
/// pane.completeMediaProcessing();
/// ```
pub fn completeMediaProcessing(self: *Pane) void {
    self.actorFinished();
    self.media.finishSealed();
}

/// Rolls back a media actor that could not be scheduled.
///
/// ```zig
/// pane.cancelMediaProcessing();
/// ```
pub fn cancelMediaProcessing(self: *Pane) void {
    self.completeMediaProcessing();
}

/// Commits graphics damage after quota enforcement and refreshes whether
/// the active media screen still contains images.
///
/// ```zig
/// pane.refreshGraphicsProjection();
/// ```
pub fn refreshGraphicsProjection(self: *Pane) void {
    self.observeGraphicsDamage();
    self.graphics_present = self.media.terminal.screens.active.kitty_images.images.count() != 0;
}

/// Processes a sealed media batch through explicit resource borrows.
/// Example: `pane.processMedia(size, &stats);`.
pub fn processMedia(self: *Pane, current_size: core.TerminalSize, stats: *Stats) void {
    var processor = self.mediaProcessor();
    processor.processMedia(current_size, stats);
}

fn mediaProcessor(self: *Pane) Processor {
    return .{
        .state = &self.media_ingestion,
        .media = &self.media,
        .media_allocator = &self.media_allocator,
        .graphics_limits = self.graphics_limits,
        .graphics_storage_limit = self.graphics_storage_limit,
        .io = self.io,
        .responses = .{ .context = &self.pty_responses, .write_fn = struct {
            fn write(context: *anyopaque, bytes: []const u8) void {
                const queue: *PtyResponseQueue = @ptrCast(@alignCast(context));
                _ = queue.push(bytes);
            }
        }.write },
    };
}

/// Records one attachment gaining or losing shared-memory transport, so
/// the media actor freezes generations only while somebody can adopt them.
///
/// ```zig
/// pane.noteSharedTransport(true);
/// ```
pub fn noteSharedTransport(self: *Pane, shared: bool) void {
    self.media_ingestion.noteSharedTransport(shared);
}

/// Freezes available image generations for shared-memory clients.
/// Example: `pane.prepareSharedTransfers(&stats);`.
pub fn prepareSharedTransfers(self: *Pane, stats: *Stats) void {
    var processor = self.mediaProcessor();
    processor.prepareSharedTransfers(stats);
}

pub fn queueHistoryInput(self: *Pane, observation: ObserverInputObservation) void {
    self.history_observer.queueInput(observation);
}

/// Enqueues one complete client message for the PTY writer or records the
/// complete message as dropped when the bounded queue has no room.
///
/// ```zig
/// const queued = pane.queuePtyInput(bytes);
/// ```
pub fn queuePtyInput(self: *Pane, bytes: []const u8) bool {
    return self.input_queue.push(bytes);
}

/// Acquires the pane allocation for one asynchronous PTY read.
///
/// ```zig
/// if (!pane.beginPtyOutputRead()) {
///     return;
/// }
/// ```
pub fn beginPtyOutputRead(self: *Pane) bool {
    if (self.output_pending or self.output_done or self.ingest_pending) {
        return false;
    }

    self.output_pending = true;
    self.actorStarted();
    return true;
}

/// Releases a completed read and records whether the output stream ended.
///
/// ```zig
/// pane.completePtyOutputRead(.data);
/// ```
pub fn completePtyOutputRead(self: *Pane, result: pane_namespace.PtyOutputReadResult) void {
    std.debug.assert(self.output_pending);
    std.debug.assert(!self.ingest_pending);

    self.output_pending = false;
    self.actorFinished();

    if (result == .finished) {
        self.output_done = true;
    }
}

/// Rolls back a read actor that could not be scheduled.
///
/// ```zig
/// pane.cancelPtyOutputRead();
/// ```
pub fn cancelPtyOutputRead(self: *Pane) void {
    std.debug.assert(self.output_pending);

    self.output_pending = false;
    self.actorFinished();
}

/// Permanently closes the output stream after a failure outside a read.
///
/// ```zig
/// pane.finishPtyOutput();
/// ```
pub fn finishPtyOutput(self: *Pane) void {
    std.debug.assert(!self.output_pending);
    std.debug.assert(!self.ingest_pending);
    self.output_done = true;
}

/// Borrows the freshly read bytes while one VT ingest actor owns them.
///
/// ```zig
/// const bytes = pane.beginOutputIngest(output_len);
/// ```
pub fn beginOutputIngest(self: *Pane, output_len: u16) []const u8 {
    std.debug.assert(!self.ingest_pending);
    std.debug.assert(!self.output_pending);
    std.debug.assert(output_len != 0);
    std.debug.assert(output_len <= self.output_buffer.len);

    self.ingest_pending = true;
    self.actorStarted();
    return self.output_buffer[0..output_len];
}

/// Releases the output buffer after VT ingestion completes.
///
/// ```zig
/// pane.completeOutputIngest();
/// ```
pub fn completeOutputIngest(self: *Pane) void {
    std.debug.assert(self.ingest_pending);

    self.ingest_pending = false;
    self.actorFinished();
    self.applyTerminalColors();
}

/// Rolls back an ingest actor that could not be scheduled.
///
/// ```zig
/// pane.cancelOutputIngest();
/// ```
pub fn cancelOutputIngest(self: *Pane) void {
    self.completeOutputIngest();
}

/// Borrows the head response until one asynchronous write settles.
/// Producers may append behind it, but no second consumer can start.
///
/// ```zig
/// const response = pane.beginPtyResponseWrite() orelse return;
/// ```
pub fn beginPtyResponseWrite(self: *Pane) ?[]const u8 {
    if (self.response_pending) {
        return null;
    }

    const response = self.pty_responses.peek() orelse return null;
    self.response_pending = true;
    self.actorStarted();
    return response;
}

/// Releases the response borrow, removing only the written head on
/// success or clearing a queue that can no longer reach the child.
///
/// ```zig
/// pane.completePtyResponseWrite(.succeeded);
/// ```
pub fn completePtyResponseWrite(self: *Pane, result: pane_namespace.PtyWriteResult) void {
    std.debug.assert(self.response_pending);

    self.response_pending = false;
    self.actorFinished();

    switch (result) {
        .succeeded => self.pty_responses.pop(),
        .failed => self.pty_responses.clear(),
    }
}

/// Rolls back a response whose actor could not be scheduled, preserving
/// the queue head for the next attempt.
///
/// ```zig
/// pane.cancelPtyResponseWrite();
/// ```
pub fn cancelPtyResponseWrite(self: *Pane) void {
    std.debug.assert(self.response_pending);

    self.response_pending = false;
    self.actorFinished();
}

/// Borrows the next stable queue chunk for one asynchronous PTY write.
/// Repeated calls return null until that write completes or is cancelled.
///
/// ```zig
/// const bytes = pane.beginPtyInputWrite() orelse return;
/// ```
pub fn beginPtyInputWrite(self: *Pane) ?[]const u8 {
    if (self.input_write_pending) {
        return null;
    }

    const bytes = self.input_queue.nextChunk() orelse return null;
    self.input_write_pending = true;
    self.input_write_len = bytes.len;
    self.actorStarted();
    return bytes;
}

/// Releases the in-flight write borrow, consuming its exact queue prefix
/// on success or stopping and clearing the input pump on PTY failure.
///
/// ```zig
/// pane.completePtyInputWrite(.succeeded);
/// ```
pub fn completePtyInputWrite(self: *Pane, result: pane_namespace.PtyWriteResult) void {
    std.debug.assert(self.input_write_pending);
    std.debug.assert(self.input_write_len != 0);

    const written = self.input_write_len;
    self.input_write_pending = false;
    self.input_write_len = 0;
    self.actorFinished();

    switch (result) {
        .succeeded => self.input_queue.consume(written),
        .failed => self.input_queue.clear(),
    }
}

/// Rolls back a write that could not be scheduled without consuming the
/// bytes, allowing a later scheduling attempt to retry the same prefix.
///
/// ```zig
/// pane.cancelPtyInputWrite();
/// ```
pub fn cancelPtyInputWrite(self: *Pane) void {
    std.debug.assert(self.input_write_pending);
    std.debug.assert(self.input_write_len != 0);

    self.input_write_pending = false;
    self.input_write_len = 0;
    self.actorFinished();
}

pub fn queueHistoryOutput(self: *Pane, observation: ObserverOutputObservation) void {
    self.history_observer.queueOutput(observation);
}

/// Seals pending history work and borrows the pane allocation for one
/// observation actor. Empty observers return null without changing state.
///
/// ```zig
/// const observation = pane.beginHistoryObservation() orelse return;
/// ```
pub fn beginHistoryObservation(self: *Pane) ?HistoryObservationBorrow {
    if (!self.history_observer.seal()) {
        return null;
    }

    self.actorStarted();
    return .{
        .current_size = self.size,
        .process_cache = self.agent_process_cache,
    };
}

/// Releases a completed observer actor, commits its CWD and process-cache
/// projection, and reports the previous process evidence to the caller.
///
/// ```zig
/// const transition = pane.completeHistoryObservation(probe.cache);
/// ```
pub fn completeHistoryObservation(self: *Pane, process_cache: Cache) HistoryObservationCompletion {
    self.actorFinished();
    self.history_observer.finishSealed();

    const cwd_changed = self.updateObservedCwd();
    const previous_process = self.agent_process_cache;
    self.agent_process_cache = process_cache;

    if (!std.mem.eql(u8, previous_process.name(), process_cache.name())) {
        revisions.advance(&self.foreground_revision);
    }

    return .{
        .previous_process = previous_process,
        .cwd_changed = cwd_changed,
        .shell_foreground = agent_process.shellForeground(process_cache, self.session.processId()),
    };
}

/// Rolls back an observation actor that could not be scheduled.
///
/// ```zig
/// pane.cancelHistoryObservation();
/// ```
pub fn cancelHistoryObservation(self: *Pane) void {
    self.actorFinished();
    self.history_observer.finishSealed();
}

/// Replays the pane's sealed observation batch and records completed
/// commands against its current session.
///
/// ```zig
/// pane.processHistoryObservation(.{ .size = size, .provider = provider }, &stats);
/// ```
pub fn processHistoryObservation(self: *Pane, context: struct { size: core.TerminalSize, provider: core.AgentProvider }, stats: *HistoryStats) void {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_module.read(self.session.processId(), &cwd_buffer);
    var capture_context: CaptureContext = .{ .pane = self, .observation_stats = stats };
    self.history_observer.processSealed(.{
        .cwd = cwd,
        .current_size = context.size,
        .stats = stats,
        .provider = context.provider,
    }, &capture_context);
}

fn updateObservedCwd(self: *Pane) bool {
    return self.cwd.update(self.history_observer.currentCwd());
}

pub fn observeGraphicsDamage(self: *Pane) void {
    const storage = &self.media.terminal.screens.active.kitty_images;
    if (!storage.dirty) {
        return;
    }
    revisions.advance(&self.graphics_revision);
    storage.dirty = false;
}

pub fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pane: *Pane = @fieldParentPtr("stream", stream);
    _ = pane.pty_responses.push(response);
}

pub fn reportProgress(handler: *vt.TerminalStream.Handler, report: vt.osc.Command.ProgressReport) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pane: *Pane = @fieldParentPtr("stream", stream);
    const state: core.PaneProgressState = switch (report.state) {
        .remove => .remove,
        .set => .set,
        .@"error" => .@"error",
        .indeterminate => .indeterminate,
        .pause => .pause,
    };
    pane.applyProgress(state, report.progress);
}

/// Drops the progress a foreground job reported once the shell owns the
/// terminal again. OSC 9;4 describes the running job, and a job that was
/// interrupted or killed never sends the removal itself, so the report
/// would otherwise outlive it until the next job replaced it.
///
/// ```zig
/// pane.expireProgress(pane.session.shellForeground() orelse false);
/// ```
pub fn expireProgress(self: *Pane, shell_foreground: bool) void {
    if (!shell_foreground) {
        return;
    }

    self.applyProgress(.remove, null);
}

fn applyProgress(self: *Pane, state: core.PaneProgressState, percent: ?u8) void {
    if (self.progress_state == state and self.progress_percent == percent) {
        return;
    }

    self.progress_state = state;
    self.progress_percent = percent;
    revisions.advance(&self.progress_revision);
}

pub fn writeMediaPty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    if (!std.mem.startsWith(u8, response, "\x1b_G")) {
        return;
    }
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const media: *Pipeline = @fieldParentPtr("stream", stream);
    const pane: *Pane = @fieldParentPtr("media", media);
    _ = pane.pty_responses.push(response);
}

pub fn reportSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const pane: *Pane = @fieldParentPtr("stream", stream);
    if (pane.size.cell_width_px == 0 or pane.size.cell_height_px == 0) {
        return null;
    }
    return .{
        .rows = pane.size.rows,
        .columns = pane.size.cols,
        .cell_width = pane.size.cell_width_px,
        .cell_height = pane.size.cell_height_px,
    };
}

pub const AgentCommand = @import("AgentCommand.zig");

/// Captures runtime-owned metadata without borrowing the observation worker's VT.
/// Call only on the runtime thread. Example: `_ = pane.recordAgentCommand(report);`.
pub fn recordAgentCommand(self: *Pane, report: AgentCommand) bool {
    const sequence = self.history_sequence.reserve() orelse return false;

    return self.history_service.recordAgentCommand(self.io, .{
        .context = .{
            .session_id = self.history_session_id,
            .pane_id = self.id,
            .location = self.location,
            .sequence = sequence,
            .workspace_path = self.workspace_path,
            .cols = self.size.cols,
            .rows = self.size.rows,
        },
        .command = report.command,
        .provider = report.provider,
        .tool_call_id = report.tool_call_id,
        .origin = report.origin,
        .phase = report.phase,
        .redact = report.redact,
    });
}

pub const CaptureContext = @import("CaptureContext.zig");
const TextMetadataCapture = @import("TextMetadataCapture.zig");

/// Marks the next completed command as submitted by automation. Called
/// when control-API text or a restored resume command carries Enter.
///
/// ```zig
/// pane.noteInjectedSubmission();
/// ```
pub fn noteInjectedSubmission(self: *Pane) void {
    _ = self.injected_submissions.fetchAdd(1, .monotonic);
}

pub fn finishHistory(self: *Pane) void {
    if (self.history_session_finished) {
        return;
    }
    var capture_context: CaptureContext = .{ .pane = self };
    if (self.history_observer.enabled) {
        self.history_observer.tracker.interrupt(pane_namespace.historyClock(self.io), &capture_context);
    }
    if (self.history_session_started) {
        _ = self.history_service.finishSession(self.io, .{
            .id = self.history_session_id,
            .finished_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds(),
        });
    }
    self.history_session_finished = true;
}

pub fn queueExitedHistory(self: *Pane, exit: exit_module.Exit) void {
    if (self.history_exit_queued) {
        return;
    }
    self.history_observer.queueShellExit(pane_namespace.historyClock(self.io), exit.code());
    self.history_exit_queued = true;
}

/// True only when no actor task can still access the pane allocation.
/// Scheduling owns one count and consuming its `PaneKey` result releases
/// it, so adding a new actor cannot silently bypass the lifetime proof by
/// forgetting to extend a list of operation-specific flags.
///
/// ```zig
/// if (pane.readyToDestroy()) {
///     pane.destroy();
/// }
/// ```
pub fn readyToDestroy(self: *const Pane) bool {
    return self.exit != null and self.output_done and
        self.actor_count == 0 and
        self.history_observer.worker == null and
        !self.history_observer.hasPending() and
        self.media.worker == null and
        !self.media.hasPending() and
        self.pty_responses.len == 0;
}

/// Replaces host defaults without changing child overrides or cell styles.
/// An ingest actor never shares mutable VT state with this operation.
/// Example: `pane.setTerminalColors(.{ .background = .{ 16, 16, 16 } });`.
pub fn setTerminalColors(self: *Pane, colors: core.TerminalColors) void {
    self.pending_terminal_colors = colors;
    if (!self.ingest_pending) {
        self.applyTerminalColors();
    }
}

fn applyTerminalColors(self: *Pane) void {
    const colors = self.pending_terminal_colors orelse return;
    std.debug.assert(!self.ingest_pending);
    const foreground = terminalRgb(colors.foreground);
    const background = terminalRgb(colors.background);
    var palette = vt.color.default;
    if (colors.palette) |configured| {
        for (configured, 0..) |rgb, index| {
            palette[index] = terminalRgb(rgb).?;
        }
    }
    self.pending_terminal_colors = null;
    if (std.meta.eql(self.terminal.colors.foreground.default, foreground) and
        std.meta.eql(self.terminal.colors.background.default, background) and
        std.meta.eql(self.terminal.colors.palette.original, palette))
    {
        return;
    }

    self.terminal.colors.foreground.default = foreground;
    self.terminal.colors.background.default = background;
    self.terminal.colors.palette.changeDefault(palette);
    self.terminal.flags.dirty.palette = true;
    self.render_pending = true;
    self.semantic_colors_dirty = true;
    self.dirty = true;
}

fn terminalRgb(color: ?[3]u8) ?vt.color.RGB {
    const rgb = color orelse return null;
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

pub fn resize(self: *Pane, size: core.TerminalSize) !void {
    try self.requestResize(size);
    try self.applyPendingResize();
}

pub fn requestResize(self: *Pane, size: core.TerminalSize) !void {
    if (std.meta.eql(self.pending_size orelse self.size, size)) {
        return;
    }
    try self.session.resize(.{
        .cols = size.cols,
        .rows = size.rows,
        .cell_width_px = size.cell_width_px,
        .cell_height_px = size.cell_height_px,
    });
    self.pending_size = size;
}

pub fn applyPendingResize(self: *Pane) !void {
    const size = self.pending_size orelse return;
    self.search_revision +%= 1;
    {
        const terminal_allocations = core.enterTerminalAllocations();
        defer terminal_allocations.restore();
        try self.stream.handler.resize(.{
            .cols = size.cols,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
                .width = size.cell_width_px,
                .height = size.cell_height_px,
            } else null,
        });
    }
    self.observeGraphicsDamage();
    try pane_namespace.resizeScreenStorage(.{
        .gpa = self.gpa,
        .screen = &self.screen,
        .damaged_rows = &self.damaged_rows,
        .cols = size.cols,
        .rows = size.rows,
    });
    // Committed only after every fallible step: a failure above leaves the
    // pending size in place for a retry and the pane fully coherent.
    self.size = size;
    self.pending_size = null;
    self.history_observer.queueResize(size);
    self.media.queueResize(size);
    try self.render(true);
}

/// Whether the child is inside a synchronized-output block (DEC private
/// mode 2026) and its frames must be held. A client of that mode - neovim
/// is one - repaints without hiding the cursor and relies on the terminal
/// presenting only the finished screen; a frame emitted mid-block shows
/// the cursor wherever the repaint happens to be. The deadline matches
/// ghostty's and exists so a child that never closes the block cannot
/// freeze its pane.
///
/// ```zig
/// if (pane.holdFrames(io)) {
///     return;
/// }
/// ```
pub fn holdFrames(self: *Pane, io: std.Io) bool {
    if (!self.terminal.modes.get(.synchronized_output)) {
        self.sync_hold_started_ns = null;
        return false;
    }
    const now_ns: u64 = @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds, 0));
    const started = self.sync_hold_started_ns orelse {
        self.sync_hold_started_ns = now_ns;
        return true;
    };
    return now_ns -| started < pane_namespace.max_sync_hold_ns;
}

pub fn render(self: *Pane, force: bool) !void {
    {
        const terminal_allocations = core.enterTerminalAllocations();
        defer terminal_allocations.restore();
        try self.render_state.update(self.gpa, &self.terminal);
    }
    try self.text_metadata.update(self.gpa, &self.render_state);
    const force_all = force or self.semantic_colors_dirty;
    core.profiling.add(.runtime_blit, 1);
    _ = vtgrid.blit(.{
        .buffer = &self.screen,
        .area = self.screen.area(),
        .terminal = &self.terminal,
        .state = &self.render_state,
        .options = .{ .force = force_all, .damaged_rows = self.damaged_rows },
    });
    self.semantic_colors_dirty = false;
    self.render_pending = false;
    revisions.advance(&self.cell_revision);
    const cursor = self.render_state.cursor;
    self.cursor = if (cursor.visible and cursor.viewport != null and
        cursor.viewport.?.x < self.screen.w and cursor.viewport.?.y < self.screen.h)
        .{
            .visible = true,
            .x = cursor.viewport.?.x,
            .y = cursor.viewport.?.y,
            .appearance = .{
                .shape = if (self.terminal.cursor.is_default) .default else switch (cursor.visual_style) {
                    .block => .block,
                    .bar => .bar,
                    .underline => .underline,
                    .block_hollow => .hollow,
                },
                .blink = cursor.blinking,
            },
        }
    else
        .{};
    self.dirty = true;
}
