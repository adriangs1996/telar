//! Long-lived runtime for protocol version 2.

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
const schema = core.schema.v2;
const diagnostics = core.diagnostics;
const output_chunk_size = 16 * 1024;
const max_workspaces = 64;
const max_tabs_per_workspace = schema.max_tabs_per_workspace;
const max_panes = schema.max_panes_per_tab;
const max_pending_responses = max_panes * 2;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const PaneOutputEvent = struct {
    pane: *Pane,
    result: anyerror!u16,
};

const PaneExitEvent = struct {
    pane: *Pane,
    result: anyerror!pty.Exit,
};

const RuntimeEvent = union(enum) {
    accepted: anyerror!core.transport.SocketChannel,
    client_message: anyerror![]u8,
    client_sent: anyerror!void,
    control_message: anyerror![]u8,
    control_sent: anyerror!void,
    history_response: anyerror!history.Response,
    pane_input_written: anyerror!void,
    pane_output: PaneOutputEvent,
    pane_exit: PaneExitEvent,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
    stopped: anyerror!void,
};

const RuntimeMetrics = struct {
    started_ns: u64,
    client_messages: u64 = 0,
    input_events: u64 = 0,
    input_bytes: u64 = 0,
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
        while (iterator.next()) |argument| {
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
    render_state: vt.RenderState = .empty,
    screen: core.ui.Buffer,
    damaged_rows: []bool,
    output_buffer: [output_chunk_size]u8 = undefined,
    cursor: schema.frame.Cursor = .{},
    foreground_override: ?vt.color.RGB = null,
    background_override: ?vt.color.RGB = null,
    semantic_colors_dirty: bool = false,
    dirty: bool = true,
    output_pending: bool = false,
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
    ) !*Pane {
        const pane = try gpa.create(Pane);
        errdefer gpa.destroy(pane);

        pane.id = id;
        pane.location = location;
        pane.io = io;
        pane.gpa = gpa;
        pane.history_service = history_service;
        pane.history_session_id = history_service.newSessionId(io);
        pane.history_sequence = 0;
        pane.history_session_started = false;
        pane.history_session_finished = false;
        pane.workspace_path = try gpa.dupe(u8, workspace_path);
        errdefer gpa.free(pane.workspace_path);
        pane.session = try .spawn(command, .{ .cols = size.cols, .rows = size.rows });
        errdefer pane.session.deinit();
        pane.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
        errdefer pane.terminal.deinit(gpa);
        pane.stream = pane.terminal.vtStream();
        errdefer pane.stream.deinit();
        pane.history_tracker = try .init(gpa, workspace_path, &pane.terminal);
        errdefer pane.history_tracker.deinit(&pane.terminal);
        pane.render_state = .empty;
        pane.screen = try .init(gpa, size.cols, size.rows);
        errdefer pane.screen.deinit();
        pane.damaged_rows = try gpa.alloc(bool, size.rows);
        errdefer gpa.free(pane.damaged_rows);
        @memset(pane.damaged_rows, false);
        pane.cursor = .{};
        pane.foreground_override = pane.terminal.colors.foreground.override;
        pane.background_override = pane.terminal.colors.background.override;
        pane.semantic_colors_dirty = false;
        pane.dirty = true;
        pane.output_pending = false;
        pane.output_done = false;
        pane.wait_pending = false;
        pane.close_requested = false;
        pane.exit = null;
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

    fn destroy(pane: *Pane) void {
        const gpa = pane.gpa;
        pane.finishHistory();
        gpa.free(pane.workspace_path);
        gpa.free(pane.damaged_rows);
        pane.screen.deinit();
        pane.render_state.deinit(gpa);
        pane.history_tracker.deinit(&pane.terminal);
        pane.stream.deinit();
        pane.terminal.deinit(gpa);
        pane.session.deinit();
        gpa.destroy(pane);
    }

    fn ingest(pane: *Pane, io: Io, bytes: []const u8, metrics: *RuntimeMetrics) !void {
        const started = diagnostics.now(io);
        var capture_context: CaptureContext = .{ .pane = pane, .metrics = metrics };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = bytes[offset..];
            const boundary = pane.history_tracker.commitBoundary(remaining);
            const slice = if (boundary) |len| remaining[0..len] else remaining;
            pane.stream.nextSlice(slice);
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
        if (!std.meta.eql(pane.foreground_override, foreground) or
            !std.meta.eql(pane.background_override, background))
        {
            pane.foreground_override = foreground;
            pane.background_override = background;
            pane.semantic_colors_dirty = true;
        }
        pane.dirty = true;
        if (comptime diagnostics.enabled) {
            metrics.ingest.observe(diagnostics.elapsed(started, diagnostics.now(io)));
        }
    }

    const CaptureContext = struct {
        pane: *Pane,
        metrics: ?*RuntimeMetrics,
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
    }

    fn finishHistory(pane: *Pane) void {
        if (pane.history_session_finished) return;
        var capture_context: CaptureContext = .{ .pane = pane, .metrics = null };
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
        if (pane.screen.w == size.cols and pane.screen.h == size.rows) return;
        try pane.session.resize(.{ .cols = size.cols, .rows = size.rows });
        try pane.terminal.resize(pane.gpa, .{ .cols = size.cols, .rows = size.rows });
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
    pane: *Pane,
    acknowledged: core.ui.Buffer,
    acknowledged_cursor: schema.frame.Cursor = .{},
    next_frame_id: u64 = 1,
    acknowledged_frame_id: u64 = 0,
    outstanding_frame_id: u64 = 0,
    frame_sent_ns: u64 = 0,
    snapshot_pending: bool = true,
    exit_sent: bool = false,

    fn init(gpa: std.mem.Allocator, pane: *Pane) !Attachment {
        return .{
            .pane = pane,
            .acknowledged = try .init(gpa, pane.screen.w, pane.screen.h),
        };
    }

    fn deinit(attachment: *Attachment) void {
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
                pane.output_pending or pane.wait_pending) continue;
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
    return serveInternal(io, gpa, endpoint, ":memory:", null);
}

pub fn serveWithHistory(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
) !void {
    return serveInternal(io, gpa, endpoint, history_path, null);
}

/// Test seam for stopping an otherwise long-lived runtime without signals.
pub fn serveUntil(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    stop: *Io.Queue(u8),
) !void {
    return serveInternal(io, gpa, endpoint, ":memory:", stop);
}

pub fn serveUntilWithHistory(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
    stop: *Io.Queue(u8),
) !void {
    return serveInternal(io, gpa, endpoint, history_path, stop);
}

fn serveInternal(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    history_path: [:0]const u8,
    stop: ?*Io.Queue(u8),
) !void {
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

    var select_storage: [17 + 2 * max_panes]RuntimeEvent = undefined;
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
    var panes: PaneStore = .{};
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
        .pane_input_written => |result| {
            pane_input_pending = false;
            result catch {
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
                try active.ingest(io, active.output_buffer[0..output_len], &metrics);
                active.output_pending = true;
                try select.concurrent(.pane_output, readPane, .{ io, active });
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
                panes.count,
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
            if (active.session.cwd(&cwd_buffer)) |cwd| active.history_tracker.updateCwd(cwd);
            var capture_context: Pane.CaptureContext = .{ .pane = active, .metrics = metrics };
            const history_input_bytes = active.history_tracker.observeInput(
                &active.terminal,
                input.bytes,
                active.session.shellForeground() orelse false,
                historyClock(io),
                &capture_context,
                Pane.captureCommand,
            );
            if (comptime diagnostics.enabled)
                metrics.history_candidate_input_bytes += history_input_bytes;
            std.debug.assert(!input_pending.*);
            @memcpy(input_buffer[0..input.bytes.len], input.bytes);
            input_pending.* = true;
            select.concurrent(.pane_input_written, writePaneInput, .{
                io,
                active.session.file(),
                input_buffer[0..input.bytes.len],
            }) catch |err| {
                input_pending.* = false;
                return err;
            };
        },
        .pane_resize => |resize| {
            const active = try attachedPane(attachments, resize.pane_id);
            try active.pane.resize(resize.size);
            _ = try active.resizeIfNeeded();
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
    if (!snapshot and span_count == 0 and !cursor_changed) {
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
    pane_count: usize,
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
    for (attachments.items) |slot| {
        const active = slot orelse continue;
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
        pane_count,
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

fn writePaneInput(io: Io, master: File, bytes: []const u8) anyerror!void {
    try master.writeStreamingAll(io, bytes);
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

fn waitPane(pane: *Pane) PaneExitEvent {
    const result = pane.session.wait();
    return .{ .pane = pane, .result = result };
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
