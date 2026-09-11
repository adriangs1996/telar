const CreationResourcesType = @import("CreationResources.zig");
const CreationRequestType = @import("CreationRequest.zig");
const AgentCommandType = @import("AgentCommand.zig");
const CaptureContextType = @import("CaptureContext.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const pane_namespace = @import("pane_namespace.zig");
const SessionType = @import("../pty/Session.zig");
const vt = @import("ghostty-vt");
const PipelineType = @import("../media/Pipeline.zig");
const PtyResponseQueue = @import("PtyResponseQueue.zig");
const GraphicsLimitsType = @import("../media/GraphicsLimits.zig");
const PaneMediaAllocatorType = @import("../media/PaneMediaAllocator.zig");
const std = @import("std");
const PaneInputQueue = @import("PaneInputQueue.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const BufferType = @import("telar-core").Buffer;
const CursorType = @import("telar-core").Cursor;
const MouseType = @import("telar-core").Mouse;
const InputModesType = @import("telar-core").InputModes;
const PointerShapeType = @import("telar-core").PointerShape;
const State = @import("../media/State.zig");
const exit_module = @import("../pty/exit.zig");
const ServiceType = @import("../history/Service.zig");
const ObserverType = @import("../history/Observer.zig");
const CacheType = @import("../process/Cache.zig");
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const model = @import("../history/model.zig");
const SequenceType = @import("../history/Sequence.zig");
const CwdState = @import("CwdState.zig");
const TitleState = @import("TitleState.zig");
const LaunchRecord = @import("LaunchRecord.zig");
const TableType = @import("telar-core").Table;
const TerminalColorsType = @import("telar-core").TerminalColors;
const max_image_bytes_per_screen_module = @import("telar-core").max_image_bytes_per_screen;
const MouseTrackingType = @import("telar-core").MouseTracking;
const TextRequest = @import("TextRequest.zig");
const TextDump = @import("TextDump.zig");
const SearchMatchType = @import("telar-core").SearchMatch;
const SearchResult = @import("SearchResult.zig");
const PaneCursor = @import("Cursor.zig");
const PaneKey = @import("PaneKey.zig");
const CellType = @import("telar-core").Cell;
const now_module = @import("telar-core").now;
const enterTerminalAllocations_module = @import("telar-core").enterTerminalAllocations;
const elapsed_module = @import("telar-core").elapsed;
const MediaProcessingBorrow = @import("MediaProcessingBorrow.zig");
const StatsType = @import("../media/Stats.zig");
const ProcessorType = @import("../media/Processor.zig");
const ObserverInputObservation = @import("../history/ObserverInputObservation.zig");
const ObserverOutputObservation = @import("../history/ObserverOutputObservation.zig");
const HistoryObservationBorrow = @import("HistoryObservationBorrow.zig");
const HistoryObservationCompletion = @import("HistoryObservationCompletion.zig");
const agent_process = @import("../process/process.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const HistoryStats = @import("../history/Stats.zig");
const cwd_module = @import("../process/cwd.zig");
const blit = @import("blit.zig");
pub const Pane = @This();

pub const CreationResources = @import("CreationResources.zig");

pub const CreationRequest = @import("CreationRequest.zig");

id: PaneIdType,
generation: u64,
location: TabLocationType,
launch_state: pane_namespace.LaunchState = .starting,
session: SessionType,
terminal: vt.Terminal,
stream: vt.TerminalStream,
media: PipelineType,
pty_responses: PtyResponseQueue = .{},
graphics_limits: GraphicsLimitsType,
graphics_storage_limit: usize,
media_allocator: PaneMediaAllocatorType,
pty_write_mutex: std.Io.Mutex = .init,
response_pending: bool = false,
input_queue: PaneInputQueue = .{},
input_write_pending: bool = false,
input_write_len: usize = 0,
size: TerminalSizeType,
render_state: vt.RenderState = .empty,
screen: BufferType,
damaged_rows: []bool,
output_buffer: [pane_namespace.output_chunk_size]u8 = undefined,
cursor: CursorType = .{},
mouse: MouseType = .{},
input_modes: InputModesType = .{},
pointer_shape: PointerShapeType = .default,
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
history_service: *ServiceType,
history_observer: ObserverType,
agent_process_cache: CacheType = .{},
foreground_revision: u64 = 1,
progress_state: PaneProgressStateType = .remove,
progress_percent: ?u8 = null,
progress_revision: u64 = 1,
history_session_id: model.SessionId,
started_at_ms: i64,
history_sequence: SequenceType = .{},
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
manifests: *const TableType,
pending_size: ?TerminalSizeType = null,
pending_terminal_colors: ?TerminalColorsType = null,
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
pub fn create(resources: CreationResourcesType, request: CreationRequestType) !*Pane {
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
        .damaged_rows = undefined,
    };
    pane.terminal = try .init(io, gpa, .{
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
        .storage_limit = @min(max_image_bytes_per_screen_module, graphics_limits.pane_bytes / 2),
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
    pane.session = try .spawn(command, .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_width_px = size.cell_width_px,
        .cell_height_px = size.cell_height_px,
    });
    pane.started_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return pane;
}

pub fn commitLaunch(pane: *Pane, shell: []const u8) void {
    pane.launch_state.commit();
    pane.history_session_started = pane.history_service.startSession(pane.io, .{
        .session_id = pane.history_session_id,
        .pane_id = pane.id,
        .location = pane.location,
        .workspace_path = pane.workspace_path,
        .shell = shell,
        .started_at_ms = pane.started_at_ms,
    });
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

pub fn mouseState(pane: *const Pane) MouseType {
    const modes = &pane.terminal.modes;
    const tracking: MouseTrackingType = if (modes.get(.mouse_event_any))
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
pub fn dumpText(pane: *const Pane, request: TextRequest, storage: []u8) TextDump {
    const screen: *const vt.Screen = pane.terminal.screens.active;
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
pub fn searchText(pane: *const Pane, needle: []const u8, storage: []SearchMatchType) SearchResult {
    std.debug.assert(!pane.ingest_pending);
    var cursor = PaneCursor.init(needle);
    while (!(cursor.advance(pane) catch unreachable)) {}
    const count = @min(storage.len, cursor.count);
    @memcpy(storage[0..count], cursor.matches[0..count]);
    return .{ .count = @intCast(count), .truncated = cursor.truncated or cursor.count > count };
}

pub fn key(pane: *const Pane) PaneKey {
    return .{ .id = pane.id, .generation = pane.generation };
}

/// Ghostty's page allocator size: the same counter `max_scrollback_bytes`
/// prunes against, covering the active grid plus retained history.
///
/// ```zig
/// const retained_bytes = pane.vtScrollbackBytes();
/// ```
pub fn vtScrollbackBytes(pane: *const Pane) usize {
    var total: usize = 0;
    for (std.enums.values(vt.ScreenSet.Key)) |screen_key| {
        const screen = pane.terminal.screens.get(screen_key) orelse continue;
        total += screen.pages.page_size;
    }
    return total;
}

pub fn vtScreenBytes(pane: *const Pane) usize {
    return pane.screen.cells.len * @sizeOf(CellType);
}

pub fn actorStarted(pane: *Pane) void {
    std.debug.assert(pane.actor_count < 8);
    pane.actor_count += 1;
}

pub fn actorFinished(pane: *Pane) void {
    std.debug.assert(pane.actor_count != 0);
    pane.actor_count -= 1;
}

/// Borrows the pane allocation until its child-wait actor completes.
///
/// ```zig
/// if (!pane.beginExitWait()) {
///     return;
/// }
/// ```
pub fn beginExitWait(pane: *Pane) bool {
    if (pane.wait_pending or pane.exit != null) {
        return false;
    }

    pane.wait_pending = true;
    pane.actorStarted();
    return true;
}

/// Rolls back a child-wait actor that could not be scheduled.
///
/// ```zig
/// pane.cancelExitWait();
/// ```
pub fn cancelExitWait(pane: *Pane) void {
    std.debug.assert(pane.wait_pending);

    pane.wait_pending = false;
    pane.actorFinished();
}

pub fn completeExitWait(pane: *Pane, exit: exit_module.Exit) void {
    std.debug.assert(pane.wait_pending);

    pane.wait_pending = false;
    pane.exit = exit;
    pane.actorFinished();
}

pub fn pointerShape(pane: *const Pane) PointerShapeType {
    return switch (pane.terminal.mouse_shape) {
        inline else => |shape| @field(PointerShapeType, @tagName(shape)),
    };
}

pub fn inputModeState(pane: *const Pane) InputModesType {
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
    pane.media_ingestion.prepared_transfers.discardAll(&pane.media_allocator);
    pane.media_ingestion.transfer_preparation.deinit(&pane.media_allocator);
    pane.media.deinit();
    pane.stream.deinit();
    pane.media_allocator.detach();
    pane.terminal.deinit(gpa);
    pane.session.deinit();
    gpa.destroy(pane);
}

/// Admits at most 32 ASCII cells on the cursor's resident row. No parser
/// continuation, wrapping, style migration, hyperlink or grapheme cleanup
/// can enter this path. Ghostty still performs the actual interpretation.
/// Call only while holding the VT borrow, before starting its actor.
/// Example: `if (pane.canInlineOutput(bytes)) { finishIngestInline(); }`.
pub fn canInlineOutput(pane: *const Pane, bytes: []const u8) bool {
    std.debug.assert(pane.ingest_pending);

    if (bytes.len == 0 or bytes.len > 32 or !pane.stream.ground()) {
        return false;
    }

    const terminal = &pane.terminal;
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

pub fn ingest(pane: *Pane, io: std.Io, bytes: []const u8) !u64 {
    pane.search_revision +%= 1;
    const started = now_module(io);
    {
        const terminal_allocations = enterTerminalAllocations_module();
        defer terminal_allocations.restore();
        pane.stream.nextSlice(bytes);
    }
    const foreground = pane.terminal.colors.foreground.override;
    const background = pane.terminal.colors.background.override;
    pane.mouse = pane.mouseState();
    pane.input_modes = pane.inputModeState();
    pane.pointer_shape = pane.pointerShape();
    _ = pane.title.observe(pane.terminal.getTitle() orelse "");
    if (!std.meta.eql(pane.foreground_override, foreground) or
        !std.meta.eql(pane.background_override, background))
    {
        pane.foreground_override = foreground;
        pane.background_override = background;
        pane.semantic_colors_dirty = true;
    }
    pane.render_pending = true;
    pane.dirty = true;
    return elapsed_module(started, now_module(io));
}

pub fn queueMediaOutput(pane: *Pane, bytes: []const u8) void {
    pane.media.queueOutput(bytes);
}

/// Seals pending graphics work and borrows the pane allocation for one
/// media actor. Empty pipelines return null without changing state.
///
/// ```zig
/// const media = pane.beginMediaProcessing() orelse return;
/// ```
pub fn beginMediaProcessing(pane: *Pane) ?MediaProcessingBorrow {
    if (!pane.media.seal()) {
        return null;
    }

    pane.actorStarted();
    return .{ .current_size = pane.size };
}

/// Releases one completed media actor and its sealed batch.
///
/// ```zig
/// pane.completeMediaProcessing();
/// ```
pub fn completeMediaProcessing(pane: *Pane) void {
    pane.actorFinished();
    pane.media.finishSealed();
}

/// Rolls back a media actor that could not be scheduled.
///
/// ```zig
/// pane.cancelMediaProcessing();
/// ```
pub fn cancelMediaProcessing(pane: *Pane) void {
    pane.completeMediaProcessing();
}

/// Commits graphics damage after quota enforcement and refreshes whether
/// the active media screen still contains images.
///
/// ```zig
/// pane.refreshGraphicsProjection();
/// ```
pub fn refreshGraphicsProjection(pane: *Pane) void {
    pane.observeGraphicsDamage();
    pane.graphics_present = pane.media.terminal.screens.active.kitty_images.images.count() != 0;
}

/// Processes a sealed media batch through explicit resource borrows.
/// Example: `pane.processMedia(size, &stats);`.
pub fn processMedia(pane: *Pane, current_size: TerminalSizeType, stats: *StatsType) void {
    var processor = pane.mediaProcessor();
    processor.processMedia(current_size, stats);
}

fn mediaProcessor(pane: *Pane) ProcessorType {
    return .{
        .state = &pane.media_ingestion,
        .media = &pane.media,
        .media_allocator = &pane.media_allocator,
        .graphics_limits = pane.graphics_limits,
        .graphics_storage_limit = pane.graphics_storage_limit,
        .io = pane.io,
        .responses = .{ .context = &pane.pty_responses, .write_fn = struct {
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
pub fn noteSharedTransport(pane: *Pane, shared: bool) void {
    pane.media_ingestion.noteSharedTransport(shared);
}

/// Freezes available image generations for shared-memory clients.
/// Example: `pane.prepareSharedTransfers(&stats);`.
pub fn prepareSharedTransfers(pane: *Pane, stats: *StatsType) void {
    var processor = pane.mediaProcessor();
    processor.prepareSharedTransfers(stats);
}

pub fn queueHistoryInput(pane: *Pane, observation: ObserverInputObservation) void {
    pane.history_observer.queueInput(observation);
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

/// Acquires the pane allocation for one asynchronous PTY read.
///
/// ```zig
/// if (!pane.beginPtyOutputRead()) {
///     return;
/// }
/// ```
pub fn beginPtyOutputRead(pane: *Pane) bool {
    if (pane.output_pending or pane.output_done or pane.ingest_pending) {
        return false;
    }

    pane.output_pending = true;
    pane.actorStarted();
    return true;
}

/// Releases a completed read and records whether the output stream ended.
///
/// ```zig
/// pane.completePtyOutputRead(.data);
/// ```
pub fn completePtyOutputRead(pane: *Pane, result: pane_namespace.PtyOutputReadResult) void {
    std.debug.assert(pane.output_pending);
    std.debug.assert(!pane.ingest_pending);

    pane.output_pending = false;
    pane.actorFinished();

    if (result == .finished) {
        pane.output_done = true;
    }
}

/// Rolls back a read actor that could not be scheduled.
///
/// ```zig
/// pane.cancelPtyOutputRead();
/// ```
pub fn cancelPtyOutputRead(pane: *Pane) void {
    std.debug.assert(pane.output_pending);

    pane.output_pending = false;
    pane.actorFinished();
}

/// Permanently closes the output stream after a failure outside a read.
///
/// ```zig
/// pane.finishPtyOutput();
/// ```
pub fn finishPtyOutput(pane: *Pane) void {
    std.debug.assert(!pane.output_pending);
    std.debug.assert(!pane.ingest_pending);
    pane.output_done = true;
}

/// Borrows the freshly read bytes while one VT ingest actor owns them.
///
/// ```zig
/// const bytes = pane.beginOutputIngest(output_len);
/// ```
pub fn beginOutputIngest(pane: *Pane, output_len: u16) []const u8 {
    std.debug.assert(!pane.ingest_pending);
    std.debug.assert(!pane.output_pending);
    std.debug.assert(output_len != 0);
    std.debug.assert(output_len <= pane.output_buffer.len);

    pane.ingest_pending = true;
    pane.actorStarted();
    return pane.output_buffer[0..output_len];
}

/// Releases the output buffer after VT ingestion completes.
///
/// ```zig
/// pane.completeOutputIngest();
/// ```
pub fn completeOutputIngest(pane: *Pane) void {
    std.debug.assert(pane.ingest_pending);

    pane.ingest_pending = false;
    pane.actorFinished();
    pane.applyTerminalColors();
}

/// Rolls back an ingest actor that could not be scheduled.
///
/// ```zig
/// pane.cancelOutputIngest();
/// ```
pub fn cancelOutputIngest(pane: *Pane) void {
    pane.completeOutputIngest();
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
pub fn completePtyResponseWrite(pane: *Pane, result: pane_namespace.PtyWriteResult) void {
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
pub fn completePtyInputWrite(pane: *Pane, result: pane_namespace.PtyWriteResult) void {
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

pub fn queueHistoryOutput(pane: *Pane, observation: ObserverOutputObservation) void {
    pane.history_observer.queueOutput(observation);
}

/// Seals pending history work and borrows the pane allocation for one
/// observation actor. Empty observers return null without changing state.
///
/// ```zig
/// const observation = pane.beginHistoryObservation() orelse return;
/// ```
pub fn beginHistoryObservation(pane: *Pane) ?HistoryObservationBorrow {
    if (!pane.history_observer.seal()) {
        return null;
    }

    pane.actorStarted();
    return .{
        .current_size = pane.size,
        .process_cache = pane.agent_process_cache,
    };
}

/// Releases a completed observer actor, commits its CWD and process-cache
/// projection, and reports the previous process evidence to the caller.
///
/// ```zig
/// const transition = pane.completeHistoryObservation(probe.cache);
/// ```
pub fn completeHistoryObservation(pane: *Pane, process_cache: CacheType) HistoryObservationCompletion {
    pane.actorFinished();
    pane.history_observer.finishSealed();

    const cwd_changed = pane.updateObservedCwd();
    const previous_process = pane.agent_process_cache;
    pane.agent_process_cache = process_cache;

    if (!std.mem.eql(u8, previous_process.name(), process_cache.name())) {
        pane.foreground_revision +%= 1;

        if (pane.foreground_revision == 0) {
            pane.foreground_revision = 1;
        }
    }

    return .{
        .previous_process = previous_process,
        .cwd_changed = cwd_changed,
        .shell_foreground = agent_process.shellForeground(process_cache, pane.session.processId()),
    };
}

/// Rolls back an observation actor that could not be scheduled.
///
/// ```zig
/// pane.cancelHistoryObservation();
/// ```
pub fn cancelHistoryObservation(pane: *Pane) void {
    pane.actorFinished();
    pane.history_observer.finishSealed();
}

/// Replays the pane's sealed observation batch and records completed
/// commands against its current session.
///
/// ```zig
/// pane.processHistoryObservation(.{ .size = size, .provider = provider }, &stats);
/// ```
pub fn processHistoryObservation(pane: *Pane, context: struct { size: TerminalSizeType, provider: AgentProviderType }, stats: *HistoryStats) void {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_module.read(pane.session.processId(), &cwd_buffer);
    var capture_context: CaptureContextType = .{ .pane = pane, .observation_stats = stats };
    pane.history_observer.processSealed(.{
        .cwd = cwd,
        .current_size = context.size,
        .stats = stats,
        .provider = context.provider,
    }, &capture_context);
}

fn updateObservedCwd(pane: *Pane) bool {
    return pane.cwd.update(pane.history_observer.currentCwd());
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
    if (!storage.dirty) {
        return;
    }
    pane.graphics_revision +%= 1;
    if (pane.graphics_revision == 0) {
        pane.graphics_revision = 1;
    }
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
    const state: PaneProgressStateType = switch (report.state) {
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
pub fn expireProgress(pane: *Pane, shell_foreground: bool) void {
    if (!shell_foreground) {
        return;
    }

    pane.applyProgress(.remove, null);
}

fn applyProgress(pane: *Pane, state: PaneProgressStateType, percent: ?u8) void {
    if (pane.progress_state == state and pane.progress_percent == percent) {
        return;
    }

    pane.progress_state = state;
    pane.progress_percent = percent;
    pane.progress_revision +%= 1;
    if (pane.progress_revision == 0) {
        pane.progress_revision = 1;
    }
}

pub fn writeMediaPty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    if (!std.mem.startsWith(u8, response, "\x1b_G")) {
        return;
    }
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const media: *PipelineType = @fieldParentPtr("stream", stream);
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
pub fn recordAgentCommand(pane: *Pane, report: AgentCommandType) bool {
    const sequence = pane.history_sequence.reserve() orelse return false;

    return pane.history_service.recordAgentCommand(pane.io, .{
        .context = .{
            .session_id = pane.history_session_id,
            .pane_id = pane.id,
            .location = pane.location,
            .sequence = sequence,
            .workspace_path = pane.workspace_path,
            .cols = pane.size.cols,
            .rows = pane.size.rows,
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

/// Marks the next completed command as submitted by automation. Called
/// when control-API text or a restored resume command carries Enter.
///
/// ```zig
/// pane.noteInjectedSubmission();
/// ```
pub fn noteInjectedSubmission(pane: *Pane) void {
    _ = pane.injected_submissions.fetchAdd(1, .monotonic);
}

pub fn finishHistory(pane: *Pane) void {
    if (pane.history_session_finished) {
        return;
    }
    var capture_context: CaptureContextType = .{ .pane = pane };
    if (pane.history_observer.enabled) {
        pane.history_observer.tracker.interrupt(pane_namespace.historyClock(pane.io), &capture_context);
    }
    if (pane.history_session_started) {
        _ = pane.history_service.finishSession(pane.io, .{
            .id = pane.history_session_id,
            .finished_at_ms = std.Io.Timestamp.now(pane.io, .real).toMilliseconds(),
        });
    }
    pane.history_session_finished = true;
}

pub fn queueExitedHistory(pane: *Pane, exit: exit_module.Exit) void {
    if (pane.history_exit_queued) {
        return;
    }
    pane.history_observer.queueShellExit(pane_namespace.historyClock(pane.io), exit.code());
    pane.history_exit_queued = true;
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
pub fn readyToDestroy(pane: *const Pane) bool {
    return pane.exit != null and pane.output_done and
        pane.actor_count == 0 and
        pane.history_observer.worker == null and
        !pane.history_observer.hasPending() and
        pane.media.worker == null and
        !pane.media.hasPending() and
        pane.pty_responses.len == 0;
}

/// Replaces host defaults without changing child overrides or cell styles.
/// An ingest actor never shares mutable VT state with this operation.
/// Example: `pane.setTerminalColors(.{ .background = .{ 16, 16, 16 } });`.
pub fn setTerminalColors(pane: *Pane, colors: TerminalColorsType) void {
    pane.pending_terminal_colors = colors;
    if (!pane.ingest_pending) {
        pane.applyTerminalColors();
    }
}

fn applyTerminalColors(pane: *Pane) void {
    const colors = pane.pending_terminal_colors orelse return;
    std.debug.assert(!pane.ingest_pending);
    const foreground = terminalRgb(colors.foreground);
    const background = terminalRgb(colors.background);
    pane.pending_terminal_colors = null;
    if (std.meta.eql(pane.terminal.colors.foreground.default, foreground) and
        std.meta.eql(pane.terminal.colors.background.default, background))
    {
        return;
    }

    pane.terminal.colors.foreground.default = foreground;
    pane.terminal.colors.background.default = background;
    pane.render_pending = true;
    pane.semantic_colors_dirty = true;
    pane.dirty = true;
}

fn terminalRgb(color: ?[3]u8) ?vt.color.RGB {
    const rgb = color orelse return null;
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

pub fn resize(pane: *Pane, size: TerminalSizeType) !void {
    try pane.requestResize(size);
    try pane.applyPendingResize();
}

pub fn requestResize(pane: *Pane, size: TerminalSizeType) !void {
    if (std.meta.eql(pane.pending_size orelse pane.size, size)) {
        return;
    }
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
    pane.search_revision +%= 1;
    {
        const terminal_allocations = enterTerminalAllocations_module();
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
    try pane_namespace.resizeScreenStorage(.{
        .gpa = pane.gpa,
        .screen = &pane.screen,
        .damaged_rows = &pane.damaged_rows,
        .cols = size.cols,
        .rows = size.rows,
    });
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
///
/// ```zig
/// if (pane.holdFrames(io)) {
///     return;
/// }
/// ```
pub fn holdFrames(pane: *Pane, io: std.Io) bool {
    if (!pane.terminal.modes.get(.synchronized_output)) {
        pane.sync_hold_started_ns = null;
        return false;
    }
    const now_ns: u64 = @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds, 0));
    const started = pane.sync_hold_started_ns orelse {
        pane.sync_hold_started_ns = now_ns;
        return true;
    };
    return now_ns -| started < pane_namespace.max_sync_hold_ns;
}

pub fn render(pane: *Pane, force: bool) !void {
    {
        const terminal_allocations = enterTerminalAllocations_module();
        defer terminal_allocations.restore();
        try pane.render_state.update(pane.gpa, &pane.terminal);
    }
    const force_all = force or pane.semantic_colors_dirty;
    _ = blit.blit(.{
        .buffer = &pane.screen,
        .area = pane.screen.area(),
        .terminal = &pane.terminal,
        .state = &pane.render_state,
        .options = .{ .force = force_all, .damaged_rows = pane.damaged_rows },
    });
    pane.semantic_colors_dirty = false;
    pane.render_pending = false;
    pane.cell_revision +%= 1;
    if (pane.cell_revision == 0) {
        pane.cell_revision = 1;
    }
    const cursor = pane.render_state.cursor;
    pane.cursor = if (cursor.visible and cursor.viewport != null and
        cursor.viewport.?.x < pane.screen.w and cursor.viewport.?.y < pane.screen.h)
        .{ .visible = true, .x = cursor.viewport.?.x, .y = cursor.viewport.?.y }
    else
        .{};
    pane.dirty = true;
}
