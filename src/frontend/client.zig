//! Disposable multi-pane client for protocol version 2.

const std = @import("std");
const core = @import("telar-core");
const client_view = @import("client_ui.zig");
const keybind = @import("keybind.zig");
const layout_mod = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const pace = @import("pace.zig");
const platform = @import("platform.zig");
const term = @import("term.zig");
const tabs_mod = @import("tabs.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema.v2;
const diagnostics = core.diagnostics;
const ui = core.ui;

const input_chunk_size = 4096;
const max_bindings = 256;
const max_binding_keys = 4;
const held_binding_bytes = 128;
const default_binding_count = 25;

pub const Action = enum {
    split_horizontal,
    split_vertical,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    toggle_sidebar,
    close_pane,
    new_tab,
    next_tab,
    previous_tab,
    select_tab_1,
    select_tab_2,
    select_tab_3,
    select_tab_4,
    select_tab_5,
    select_tab_6,
    select_tab_7,
    select_tab_8,
    select_tab_9,
    rename_tab,
    close_tab,
    move_tab_previous,
    move_tab_next,
    detach,

    pub fn parse(name: []const u8) !Action {
        if (std.mem.eql(u8, name, "split-horizontal")) return .split_horizontal;
        if (std.mem.eql(u8, name, "split-vertical")) return .split_vertical;
        if (std.mem.eql(u8, name, "focus-left")) return .focus_left;
        if (std.mem.eql(u8, name, "focus-right")) return .focus_right;
        if (std.mem.eql(u8, name, "focus-up")) return .focus_up;
        if (std.mem.eql(u8, name, "focus-down")) return .focus_down;
        if (std.mem.eql(u8, name, "toggle-sidebar")) return .toggle_sidebar;
        if (std.mem.eql(u8, name, "close-pane")) return .close_pane;
        if (std.mem.eql(u8, name, "new-tab")) return .new_tab;
        if (std.mem.eql(u8, name, "next-tab")) return .next_tab;
        if (std.mem.eql(u8, name, "previous-tab")) return .previous_tab;
        if (std.mem.eql(u8, name, "rename-tab")) return .rename_tab;
        if (std.mem.eql(u8, name, "close-tab")) return .close_tab;
        if (std.mem.eql(u8, name, "move-tab-previous")) return .move_tab_previous;
        if (std.mem.eql(u8, name, "move-tab-next")) return .move_tab_next;
        if (std.mem.eql(u8, name, "select-tab-1")) return .select_tab_1;
        if (std.mem.eql(u8, name, "select-tab-2")) return .select_tab_2;
        if (std.mem.eql(u8, name, "select-tab-3")) return .select_tab_3;
        if (std.mem.eql(u8, name, "select-tab-4")) return .select_tab_4;
        if (std.mem.eql(u8, name, "select-tab-5")) return .select_tab_5;
        if (std.mem.eql(u8, name, "select-tab-6")) return .select_tab_6;
        if (std.mem.eql(u8, name, "select-tab-7")) return .select_tab_7;
        if (std.mem.eql(u8, name, "select-tab-8")) return .select_tab_8;
        if (std.mem.eql(u8, name, "select-tab-9")) return .select_tab_9;
        if (std.mem.eql(u8, name, "detach")) return .detach;
        return error.UnknownAction;
    }
};

pub const ConfiguredBinding = keybind.Binding(Action, max_binding_keys);
const InputRouter = keybind.Router(
    Action,
    max_bindings,
    max_binding_keys,
    input_chunk_size,
    held_binding_bytes,
);

pub const Options = struct {
    arguments: []const []const u8,
    cwd: []const u8,
    endpoint: []const u8,
    bindings: []const ConfiguredBinding = &.{},
};

const ClientMetrics = struct {
    started_ns: u64,
    input_events: u64 = 0,
    input_bytes: u64 = 0,
    server_messages: u64 = 0,
    server_bytes: u64 = 0,
    frames: u64 = 0,
    frame_cells: u64 = 0,
    frame_spans: u64 = 0,
    snapshots: u64 = 0,
    composed_panes: u64 = 0,
    composed_cells: u64 = 0,
    composed_damage_cells: u64 = 0,
    full_compositions: u64 = 0,
    flushes: u64 = 0,
    scanned_cells: u64 = 0,
    flushed_cells: u64 = 0,
    flushed_bytes: u64 = 0,
    max_pending_updates: u64 = 0,
    mouse_events: u64 = 0,
    chrome_scanned_cells: u64 = 0,
    chrome_damaged_cells: u64 = 0,
    decode: diagnostics.Timing = .{},
    apply: diagnostics.Timing = .{},
    compose: diagnostics.Timing = .{},
    ack_send: diagnostics.Timing = .{},
    input_send: diagnostics.Timing = .{},
    flush: diagnostics.Timing = .{},
    draw_lateness: diagnostics.Timing = .{},
    paced_interval: diagnostics.Timing = .{},
};

const InputChunk = struct {
    bytes: [input_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(chunk: *const InputChunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};

const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    input_timeout: anyerror!void,
    binding_timeout: anyerror!void,
    resized: anyerror!void,
    server: anyerror![]u8,
    draw: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
};

const PendingSplit = struct {
    request_id: schema.RequestId,
    target_pane: schema.PaneId,
    axis: layout_mod.Axis,
};

const PendingClose = struct {
    request_id: schema.RequestId,
    pane_id: schema.PaneId,
};

const PendingTabOperation = union(enum) {
    create: schema.RequestId,
    rename: schema.RequestId,
    close: schema.RequestId,
    move: schema.RequestId,

    fn requestId(operation: PendingTabOperation) schema.RequestId {
        return switch (operation) {
            inline else => |request_id| request_id,
        };
    }
};

const PendingTabSnapshot = struct {
    request_id: schema.RequestId,
    tab_id: schema.TabId,
};

const PendingAttachment = struct {
    request_id: schema.RequestId,
    pane_id: schema.PaneId,
};

const PendingAttachments = struct {
    entries: [multiplexer.max_panes]?PendingAttachment =
        [_]?PendingAttachment{null} ** multiplexer.max_panes,

    fn add(pending: *PendingAttachments, entry: PendingAttachment) !void {
        for (&pending.entries) |*slot| {
            if (slot.* == null) {
                slot.* = entry;
                return;
            }
        }
        return error.TooManyPendingAttachments;
    }

    fn take(pending: *PendingAttachments, request_id: schema.RequestId) ?schema.PaneId {
        for (&pending.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.request_id != request_id) continue;
            slot.* = null;
            return entry.pane_id;
        }
        return null;
    }
};

pub fn run(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: Options,
) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "client-{d}",
        .{std.c.getpid()},
    ) catch "client";
    var telemetry = diagnostics.Sink.init(io, options.endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("telar needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();

    const input_file = tty.readHandle();
    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.enter_sequence);
    try writer.flush();
    defer {
        writer.writeAll(platform.leave_sequence) catch {};
        writer.flush() catch {};
    }

    var host_size = terminalSize(&tty);
    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    defer screen.deinit();
    var view = try client_view.State.init(gpa, host_size.cols, host_size.rows);
    defer view.deinit();
    var tabs = tabs_mod.Model.init(gpa);
    defer tabs.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);

    const initial_request_id: schema.RequestId = @enumFromInt(1);
    const open_payload = try schema.encodeOpenPane(send_buffer, .{
        .request_id = initial_request_id,
        .size = rectSize(view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);

    var select_storage: [8]ClientEvent = undefined;
    var select = Io.Select(ClientEvent).init(io, &select_storage);
    defer select.cancelDiscard();
    try select.concurrent(.resized, waitResize, .{ io, &watcher });
    try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var defaults = try defaultBindings();
    const configured_bindings = if (options.bindings.len == 0)
        defaults[0..]
    else
        options.bindings;
    var input_router = try InputRouter.init(configured_bindings);
    var input_started = false;
    var input_timeout_pending = false;
    var binding_timeout_pending = false;
    var next_request_id: u64 = 2;
    var workspace_snapshot_request_id: ?schema.RequestId = null;
    var tab_snapshot: ?PendingTabSnapshot = null;
    var pending_split: ?PendingSplit = null;
    var pending_close: ?PendingClose = null;
    var pending_tab_operation: ?PendingTabOperation = null;
    var pending_attachments: PendingAttachments = .{};
    var draw_pending = false;
    var pending_updates: usize = 0;
    var pacer: pace.Pacer = .{};
    var draw_due_ns: u64 = 0;
    var last_presented_ns: ?u64 = null;
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    var metrics: ClientMetrics = .{ .started_ns = diagnostics.now(io) };

    while (true) switch (try select.await()) {
        .input => |result| {
            const chunk = try result;
            if (chunk.len == 0) return 0;
            var handler = InputHandler.init(io, connection, send_buffer, &metrics, &tabs, &view, options, &next_request_id, &pending_split, &pending_close, &pending_tab_operation, &tab_snapshot);
            if (try input_router.feed(chunk.slice(), monotonic(io), &handler) == .stop)
                return 0;
            if (handler.redraw) try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
            try select.concurrent(.input, readInput, .{ io, input_file });
        },
        .input_timeout => |result| {
            try result;
            input_timeout_pending = false;
            var handler = InputHandler.init(io, connection, send_buffer, &metrics, &tabs, &view, options, &next_request_id, &pending_split, &pending_close, &pending_tab_operation, &tab_snapshot);
            if (try input_router.expireInput(monotonic(io), &handler) == .stop) return 0;
            if (handler.redraw) try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
        },
        .binding_timeout => |result| {
            try result;
            binding_timeout_pending = false;
            var handler = InputHandler.init(io, connection, send_buffer, &metrics, &tabs, &view, options, &next_request_id, &pending_split, &pending_close, &pending_tab_operation, &tab_snapshot);
            if (try input_router.expireBinding(monotonic(io), &handler) == .stop) return 0;
            if (handler.redraw) try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
            try scheduleInputTimers(io, &select, &input_router, &input_timeout_pending, &binding_timeout_pending);
        },
        .resized => |result| {
            try result;
            host_size = terminalSize(&tty);
            try screen.resize(host_size.cols, host_size.rows);
            try view.resize(host_size.cols, host_size.rows);
            if (tabs.active()) |active|
                try resizeAttached(io, connection, send_buffer, &active.model, view.workbench());
            try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
            try select.concurrent(.resized, waitResize, .{ io, &watcher });
        },
        .server => |result| {
            const payload = try result;
            const decode_started = diagnostics.now(io);
            const message = try schema.decodeServer(payload);
            if (comptime diagnostics.enabled) {
                metrics.server_messages += 1;
                metrics.server_bytes += payload.len;
                metrics.decode.observe(diagnostics.elapsed(decode_started, diagnostics.now(io)));
            }
            switch (message) {
                .pane_opened => |opened| {
                    if (opened.request_id == initial_request_id and tabs.count == 0) {
                        try tabs.bootstrap(
                            opened.pane_id,
                            opened.location,
                            rectSize(view.workbench()) orelse return error.TerminalTooSmall,
                        );
                        view.invalidate();
                        if (!input_started) {
                            try select.concurrent(.input, readInput, .{ io, input_file });
                            input_started = true;
                        }
                        const workspace_request_id = try nextRequestId(&next_request_id);
                        workspace_snapshot_request_id = workspace_request_id;
                        try connection.send(io, try schema.encodeRequestWorkspaceSnapshot(send_buffer, .{
                            .request_id = workspace_request_id,
                            .workspace = opened.location.workspace,
                        }));
                        const tab_request_id = try nextRequestId(&next_request_id);
                        tab_snapshot = .{ .request_id = tab_request_id, .tab_id = opened.location.tab_id };
                        const request = try schema.encodeRequestTabSnapshot(send_buffer, .{
                            .request_id = tab_request_id,
                            .location = opened.location,
                        });
                        try connection.send(io, request);
                    } else if (pending_split != null and
                        pending_split.?.request_id == opened.request_id)
                    {
                        const split = pending_split.?;
                        const tab = tabs.tabForPane(split.target_pane) orelse
                            return error.UnexpectedPane;
                        const model = &tab.model;
                        if (model.find(split.target_pane) != null) {
                            try model.split(split.target_pane, opened.pane_id, opened.location, split.axis, view.workbench());
                        } else {
                            try model.addDiscovered(opened.pane_id, opened.location, view.workbench());
                            try model.markAttached(opened.pane_id);
                        }
                        view.invalidate();
                        pending_split = null;
                        try resizeAttached(io, connection, send_buffer, model, view.workbench());
                    } else if (pending_attachments.take(opened.request_id)) |expected| {
                        if (expected != opened.pane_id) return error.UnexpectedPane;
                        const pane = tabs.findPane(opened.pane_id) orelse return error.UnexpectedPane;
                        pane.attached = true;
                    } else {
                        return error.UnexpectedRequest;
                    }
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .tab_snapshot => |snapshot| {
                    const pending = tab_snapshot orelse return error.UnexpectedTabSnapshot;
                    if (snapshot.request_id != pending.request_id or
                        snapshot.location.tab_id != pending.tab_id)
                        return error.UnexpectedTabSnapshot;
                    tab_snapshot = null;
                    const tab = try tabs.reconcileTab(snapshot, view.workbench());
                    const model = &tab.model;
                    view.invalidate();
                    try resizeAttached(io, connection, send_buffer, model, view.workbench());
                    for (&model.panes) |*slot| {
                        const pane = if (slot.*) |*value| value else continue;
                        if (pane.attached) continue;
                        const size = model.contentSize(pane.id, view.workbench()) orelse
                            return error.PaneTooSmall;
                        const request_id = try nextRequestId(&next_request_id);
                        const request = try schema.encodeOpenPane(send_buffer, .{
                            .request_id = request_id,
                            .target = .{ .pane = pane.id },
                            .size = size,
                            .launch = null,
                        });
                        try connection.send(io, request);
                        try pending_attachments.add(.{
                            .request_id = request_id,
                            .pane_id = pane.id,
                        });
                    }
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .workspace_snapshot => |snapshot| {
                    if (workspace_snapshot_request_id == null or
                        snapshot.request_id != workspace_snapshot_request_id.?)
                        return error.UnexpectedWorkspaceSnapshot;
                    workspace_snapshot_request_id = null;
                    try tabs.reconcileWorkspace(snapshot);
                    view.invalidate();
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .tab_created => |created| {
                    const operation = pending_tab_operation orelse return error.UnexpectedTabCreated;
                    if (operation != .create or operation.requestId() != created.request_id)
                        return error.UnexpectedTabCreated;
                    if (tabs.active()) |current| {
                        var handler = InputHandler.init(io, connection, send_buffer, &metrics, &tabs, &view, options, &next_request_id, &pending_split, &pending_close, &pending_tab_operation, &tab_snapshot);
                        try handler.detachTab(current);
                    }
                    pending_tab_operation = null;
                    _ = try tabs.addCreated(
                        created,
                        rectSize(view.workbench()) orelse return error.TerminalTooSmall,
                    );
                    view.invalidate();
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .tab_renamed => |renamed| {
                    const operation = pending_tab_operation orelse return error.UnexpectedTabRenamed;
                    if (operation != .rename or operation.requestId() != renamed.request_id)
                        return error.UnexpectedTabRenamed;
                    pending_tab_operation = null;
                    if (!tabs.rename(renamed.location.tab_id, renamed.label))
                        return error.UnexpectedTab;
                    view.invalidate();
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .tab_closed => |closed| {
                    const operation = pending_tab_operation orelse
                        return error.UnexpectedTabClosed;
                    if (operation != .close or operation.requestId() != closed.request_id)
                        return error.UnexpectedTabClosed;
                    pending_tab_operation = null;
                    const was_active = tabs.activeConst() != null and
                        tabs.activeConst().?.location.tab_id == closed.location.tab_id;
                    if (!tabs.remove(closed.location.tab_id)) return error.UnexpectedTab;
                    if (closed.workspace_closed or tabs.count == 0) return 0;
                    if (was_active) {
                        const active = tabs.active().?;
                        const request_id = try nextRequestId(&next_request_id);
                        tab_snapshot = .{ .request_id = request_id, .tab_id = active.location.tab_id };
                        try connection.send(io, try schema.encodeRequestTabSnapshot(send_buffer, .{
                            .request_id = request_id,
                            .location = active.location,
                        }));
                    }
                    view.invalidate();
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .tab_moved => |moved| {
                    const operation = pending_tab_operation orelse return error.UnexpectedTabMoved;
                    if (operation != .move or operation.requestId() != moved.request_id)
                        return error.UnexpectedTabMoved;
                    pending_tab_operation = null;
                    _ = tabs.move(moved.location.tab_id, moved.position);
                    view.invalidate();
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .pane_frame => |frame| {
                    const pane = tabs.findPane(frame.pane_id) orelse return error.UnexpectedPane;
                    if (pane.attached) {
                        if (frame.base_frame_id != 0 and
                            frame.base_frame_id != pane.applied_frame_id)
                        {
                            const request = try schema.encodeRequestSnapshot(send_buffer, .{
                                .pane_id = frame.pane_id,
                                .known_frame_id = pane.applied_frame_id,
                            });
                            try connection.send(io, request);
                        } else {
                            const apply_started = diagnostics.now(io);
                            const tab = tabs.tabForPane(frame.pane_id) orelse
                                return error.UnexpectedPane;
                            const applied = try tab.model.applyFrame(frame);
                            if (comptime diagnostics.enabled) {
                                metrics.frames += 1;
                                metrics.frame_cells += applied.cells;
                                metrics.frame_spans += applied.spans;
                                if (frame.base_frame_id == 0) metrics.snapshots += 1;
                                metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(io)));
                            }
                            try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                        }
                    }
                },
                .pane_exited => |exited| {
                    const tab = tabs.tabForPane(exited.pane_id);
                    if (tab) |value| _ = value.model.removePane(exited.pane_id);
                    view.invalidate();
                    if (pending_close != null and pending_close.?.pane_id == exited.pane_id)
                        pending_close = null;
                    if (tabs.active()) |active| {
                        if (active.model.pane_count != 0)
                            try resizeAttached(io, connection, send_buffer, &active.model, view.workbench());
                    }
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .request_failed => |failure| {
                    if (pending_split != null and
                        pending_split.?.request_id == failure.request_id)
                    {
                        pending_split = null;
                        if (tabs.active()) |active|
                            try resizeAttached(io, connection, send_buffer, &active.model, view.workbench());
                    } else if (pending_close != null and
                        pending_close.?.request_id == failure.request_id)
                    {
                        pending_close = null;
                    } else if (pending_attachments.take(failure.request_id)) |pane_id| {
                        if (tabs.tabForPane(pane_id)) |tab| _ = tab.model.removePane(pane_id);
                        view.invalidate();
                        if (tabs.active()) |active|
                            try resizeAttached(io, connection, send_buffer, &active.model, view.workbench());
                    } else if (pending_tab_operation != null and
                        pending_tab_operation.?.requestId() == failure.request_id)
                    {
                        const operation = pending_tab_operation.?;
                        pending_tab_operation = null;
                        if (operation == .close) {
                            const active = tabs.active().?;
                            const request_id = try nextRequestId(&next_request_id);
                            tab_snapshot = .{
                                .request_id = request_id,
                                .tab_id = active.location.tab_id,
                            };
                            try connection.send(io, try schema.encodeRequestTabSnapshot(send_buffer, .{
                                .request_id = request_id,
                                .location = active.location,
                            }));
                        }
                    } else {
                        std.debug.print("telar runtime: {s}\n", .{failure.message});
                        return error.RuntimeRequestFailed;
                    }
                    try requestDraw(io, &select, &pacer, &draw_pending, &draw_due_ns, &pending_updates, &metrics);
                },
                .runtime_stopping => return 0,
                .history_results => return error.UnexpectedHistoryResults,
            }
            try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
        },
        .draw => |result| {
            try result;
            draw_pending = false;
            if (comptime diagnostics.enabled)
                metrics.draw_lateness.observe(monotonic(io) -| draw_due_ns);
            if (pending_updates != 0) {
                const model = &tabs.active().?.model;
                const presented_ns = try presentModel(io, &screen, writer, connection, send_buffer, &metrics, &tabs, model, &view);
                observePresentation(&metrics, &last_presented_ns, presented_ns, true);
                pacer.record(presented_ns, draw_due_ns, pending_updates);
                pending_updates = 0;
            }
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
            const active = tabs.active().?;
            const focused = active.model.layout.focused() orelse .invalid;
            const line = formatClientTelemetry(
                &telemetry_buffer,
                io,
                &metrics,
                &pacer,
                active.location.tab_id,
                tabs.count,
                focused,
                active.model.pane_count,
                pending_updates,
                draw_pending,
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

fn readInput(io: Io, input: File) anyerror!InputChunk {
    var chunk: InputChunk = .{};
    chunk.len = @intCast(try input.readStreaming(io, &.{&chunk.bytes}));
    return chunk;
}

const InputHandler = struct {
    io: Io,
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    metrics: *ClientMetrics,
    tabs: *tabs_mod.Model,
    view: *client_view.State,
    options: Options,
    next_request_id: *u64,
    pending_split: *?PendingSplit,
    pending_close: *?PendingClose,
    pending_tab_operation: *?PendingTabOperation,
    pending_tab_snapshot: *?PendingTabSnapshot,
    redraw: bool = false,

    fn init(
        io: Io,
        connection: *core.transport.SocketChannel,
        send_buffer: []u8,
        metrics: *ClientMetrics,
        tabs: *tabs_mod.Model,
        view: *client_view.State,
        options: Options,
        next_request_id: *u64,
        pending_split: *?PendingSplit,
        pending_close: *?PendingClose,
        pending_tab_operation: *?PendingTabOperation,
        pending_tab_snapshot: *?PendingTabSnapshot,
    ) InputHandler {
        return .{
            .io = io,
            .connection = connection,
            .send_buffer = send_buffer,
            .metrics = metrics,
            .tabs = tabs,
            .view = view,
            .options = options,
            .next_request_id = next_request_id,
            .pending_split = pending_split,
            .pending_close = pending_close,
            .pending_tab_operation = pending_tab_operation,
            .pending_tab_snapshot = pending_tab_snapshot,
        };
    }

    fn activeModel(handler: *InputHandler) *multiplexer.Model {
        return &handler.tabs.active().?.model;
    }

    fn detachTab(handler: *InputHandler, tab: *tabs_mod.Tab) !void {
        for (&tab.model.panes) |*slot| {
            const pane = if (slot.*) |*item| item else continue;
            if (!pane.attached) continue;
            const payload = try schema.encodeDetachPane(handler.send_buffer, .{
                .pane_id = pane.id,
            });
            try handler.connection.send(handler.io, payload);
        }
        tabs_mod.Model.detachAll(tab);
    }

    fn selectTab(handler: *InputHandler, tab_id: schema.TabId) !void {
        if (handler.pending_tab_snapshot.* != null) return;
        const current = handler.tabs.active() orelse return;
        if (current.location.tab_id == tab_id) return;
        if (handler.tabs.indexOf(tab_id) == null) return;
        try handler.detachTab(current);
        std.debug.assert(handler.tabs.select(tab_id));
        const active = handler.tabs.active().?;
        active.model.composition_invalidated = true;
        const request_id = try nextRequestId(handler.next_request_id);
        const payload = try schema.encodeRequestTabSnapshot(handler.send_buffer, .{
            .request_id = request_id,
            .location = active.location,
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_tab_snapshot.* = .{
            .request_id = request_id,
            .tab_id = tab_id,
        };
        handler.view.invalidate();
        handler.redraw = true;
    }

    pub fn forward(handler: *InputHandler, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (handler.view.renamedTab() != null) {
            switch (handler.view.handleRenameInput(bytes)) {
                .editing, .cancelled => {},
                .submitted => |label| try handler.submitTabRename(label),
            }
            handler.redraw = true;
            return;
        }
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        const started = diagnostics.now(handler.io);
        const payload = try schema.encodePaneInput(handler.send_buffer, .{
            .pane_id = pane.id,
            .bytes = bytes,
        });
        try handler.connection.send(handler.io, payload);
        if (comptime diagnostics.enabled) {
            handler.metrics.input_events += 1;
            handler.metrics.input_bytes += bytes.len;
            handler.metrics.input_send.observe(diagnostics.elapsed(started, diagnostics.now(handler.io)));
        }
    }

    pub fn mouse(handler: *InputHandler, event: term.Event.Mouse) !void {
        if (comptime diagnostics.enabled) handler.metrics.mouse_events += 1;
        const model = handler.activeModel();
        const interaction = handler.view.handleMouse(handler.tabs, model, event);
        if (interaction.select_tab) |tab_id| try handler.selectTab(tab_id);
        if (interaction.layout_changed) {
            try resizeAttached(
                handler.io,
                handler.connection,
                handler.send_buffer,
                handler.activeModel(),
                handler.view.workbench(),
            );
        }
        handler.redraw = handler.redraw or interaction.redraw;
    }

    pub fn action(handler: *InputHandler, value: Action) !keybind.Control {
        if (handler.view.renamedTab() != null) return .continue_routing;
        switch (value) {
            .split_horizontal => try handler.beginSplit(.horizontal),
            .split_vertical => try handler.beginSplit(.vertical),
            .focus_left => handler.moveFocus(.left),
            .focus_right => handler.moveFocus(.right),
            .focus_up => handler.moveFocus(.up),
            .focus_down => handler.moveFocus(.down),
            .toggle_sidebar => {
                handler.view.toggleSidebar();
                try resizeAttached(
                    handler.io,
                    handler.connection,
                    handler.send_buffer,
                    handler.activeModel(),
                    handler.view.workbench(),
                );
                handler.redraw = true;
            },
            .close_pane => try handler.closeFocused(),
            .new_tab => try handler.createTab(),
            .next_tab => try handler.selectTabOffset(1),
            .previous_tab => try handler.selectTabOffset(-1),
            .select_tab_1 => try handler.selectTabPosition(0),
            .select_tab_2 => try handler.selectTabPosition(1),
            .select_tab_3 => try handler.selectTabPosition(2),
            .select_tab_4 => try handler.selectTabPosition(3),
            .select_tab_5 => try handler.selectTabPosition(4),
            .select_tab_6 => try handler.selectTabPosition(5),
            .select_tab_7 => try handler.selectTabPosition(6),
            .select_tab_8 => try handler.selectTabPosition(7),
            .select_tab_9 => try handler.selectTabPosition(8),
            .rename_tab => if (handler.tabs.active()) |tab| {
                handler.view.beginTabRename(tab.location.tab_id, tab.labelSlice());
                handler.redraw = true;
            },
            .close_tab => try handler.closeTab(),
            .move_tab_previous => try handler.moveTab(.previous),
            .move_tab_next => try handler.moveTab(.next),
            .detach => {
                for (handler.tabs.items[0..handler.tabs.count]) |*slot| {
                    const tab = if (slot.*) |*item| item else continue;
                    try handler.detachTab(tab);
                }
                return .stop;
            },
        }
        return .continue_routing;
    }

    fn beginSplit(handler: *InputHandler, axis: layout_mod.Axis) !void {
        if (handler.pending_split.* != null or handler.pending_close.* != null) return;
        const model = handler.activeModel();
        const pane = model.focusedPane() orelse return;
        if (!pane.attached) return;
        const location = model.location orelse return;
        const prospective = model.layout.prospectiveSplit(
            pane.id,
            axis,
            handler.view.workbench(),
        ) orelse
            return;
        const existing_size = rectSize(prospective.existing_content) orelse return;
        const new_size = rectSize(prospective.new_content) orelse return;
        const request_id = try nextRequestId(handler.next_request_id);

        const resize = try schema.encodePaneResize(handler.send_buffer, .{
            .pane_id = pane.id,
            .size = existing_size,
        });
        try handler.connection.send(handler.io, resize);
        const request = schema.encodeCreatePane(handler.send_buffer, .{
            .request_id = request_id,
            .location = location,
            .size = new_size,
            .launch = .{ .cwd = handler.options.cwd, .arguments = handler.options.arguments },
        }) catch |err| {
            try handler.restoreFocusedSize(pane.id);
            return err;
        };
        handler.connection.send(handler.io, request) catch |err| {
            try handler.restoreFocusedSize(pane.id);
            return err;
        };
        handler.pending_split.* = .{
            .request_id = request_id,
            .target_pane = pane.id,
            .axis = axis,
        };
    }

    fn restoreFocusedSize(handler: *InputHandler, pane_id: schema.PaneId) !void {
        const size = handler.activeModel().contentSize(pane_id, handler.view.workbench()) orelse return;
        const payload = try schema.encodePaneResize(handler.send_buffer, .{
            .pane_id = pane_id,
            .size = size,
        });
        try handler.connection.send(handler.io, payload);
    }

    fn moveFocus(handler: *InputHandler, direction: layout_mod.Direction) void {
        if (handler.activeModel().focusDirection(direction, handler.view.workbench()) != null) {
            handler.view.invalidate();
            handler.redraw = true;
        }
    }

    fn closeFocused(handler: *InputHandler) !void {
        if (handler.pending_close.* != null or handler.pending_split.* != null) return;
        const pane = handler.activeModel().focusedPane() orelse return;
        if (!pane.attached) return;
        const request_id = try nextRequestId(handler.next_request_id);
        const payload = try schema.encodeClosePane(handler.send_buffer, .{
            .request_id = request_id,
            .pane_id = pane.id,
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_close.* = .{ .request_id = request_id, .pane_id = pane.id };
    }

    fn createTab(handler: *InputHandler) !void {
        if (handler.pending_tab_operation.* != null) return;
        const workspace = handler.tabs.workspace orelse return;
        const request_id = try nextRequestId(handler.next_request_id);
        const payload = try schema.encodeCreateTab(handler.send_buffer, .{
            .request_id = request_id,
            .workspace = workspace,
            .size = rectSize(handler.view.workbench()) orelse return,
            .launch = .{ .cwd = handler.options.cwd, .arguments = handler.options.arguments },
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_tab_operation.* = .{ .create = request_id };
    }

    fn selectTabOffset(handler: *InputHandler, offset: isize) !void {
        if (handler.tabs.count < 2) return;
        const count: isize = @intCast(handler.tabs.count);
        const current: isize = @intCast(handler.tabs.active_index);
        const position: usize = @intCast(@mod(current + offset, count));
        try handler.selectTab(handler.tabs.items[position].?.location.tab_id);
    }

    fn selectTabPosition(handler: *InputHandler, position: usize) !void {
        if (position >= handler.tabs.count) return;
        try handler.selectTab(handler.tabs.items[position].?.location.tab_id);
    }

    fn closeTab(handler: *InputHandler) !void {
        if (handler.pending_tab_operation.* != null) return;
        const tab = handler.tabs.active() orelse return;
        const request_id = try nextRequestId(handler.next_request_id);
        try handler.detachTab(tab);
        const payload = try schema.encodeCloseTab(handler.send_buffer, .{
            .request_id = request_id,
            .location = tab.location,
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_tab_operation.* = .{ .close = request_id };
    }

    fn moveTab(handler: *InputHandler, direction: schema.TabMoveDirection) !void {
        if (handler.pending_tab_operation.* != null) return;
        const tab = handler.tabs.active() orelse return;
        const request_id = try nextRequestId(handler.next_request_id);
        const payload = try schema.encodeMoveTab(handler.send_buffer, .{
            .request_id = request_id,
            .location = tab.location,
            .direction = direction,
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_tab_operation.* = .{ .move = request_id };
    }

    fn submitTabRename(handler: *InputHandler, label: []const u8) !void {
        if (handler.pending_tab_operation.* != null) return;
        const tab_id = handler.view.renamedTab() orelse return;
        const tab = handler.tabs.find(tab_id) orelse return;
        const request_id = try nextRequestId(handler.next_request_id);
        const payload = try schema.encodeRenameTab(handler.send_buffer, .{
            .request_id = request_id,
            .location = tab.location,
            .label = label,
        });
        try handler.connection.send(handler.io, payload);
        handler.pending_tab_operation.* = .{ .rename = request_id };
        handler.view.finishTabRename();
    }
};

fn defaultBindings() ![default_binding_count]ConfiguredBinding {
    return .{
        try .parse(&.{ "ctrl+b", "%" }, .split_horizontal),
        try .parse(&.{ "ctrl+b", "\"" }, .split_vertical),
        try .parse(&.{ "ctrl+b", "left" }, .focus_left),
        try .parse(&.{ "ctrl+b", "right" }, .focus_right),
        try .parse(&.{ "ctrl+b", "up" }, .focus_up),
        try .parse(&.{ "ctrl+b", "down" }, .focus_down),
        try .parse(&.{ "ctrl+b", "s" }, .toggle_sidebar),
        try .parse(&.{ "ctrl+b", "x" }, .close_pane),
        try .parse(&.{ "ctrl+b", "d" }, .detach),
        try .parse(&.{ "ctrl+b", "c" }, .new_tab),
        try .parse(&.{ "ctrl+b", "n" }, .next_tab),
        try .parse(&.{ "ctrl+b", "p" }, .previous_tab),
        try .parse(&.{ "ctrl+b", "1" }, .select_tab_1),
        try .parse(&.{ "ctrl+b", "2" }, .select_tab_2),
        try .parse(&.{ "ctrl+b", "3" }, .select_tab_3),
        try .parse(&.{ "ctrl+b", "4" }, .select_tab_4),
        try .parse(&.{ "ctrl+b", "5" }, .select_tab_5),
        try .parse(&.{ "ctrl+b", "6" }, .select_tab_6),
        try .parse(&.{ "ctrl+b", "7" }, .select_tab_7),
        try .parse(&.{ "ctrl+b", "8" }, .select_tab_8),
        try .parse(&.{ "ctrl+b", "9" }, .select_tab_9),
        try .parse(&.{ "ctrl+b", "T" }, .rename_tab),
        try .parse(&.{ "ctrl+b", "X" }, .close_tab),
        try .parse(&.{ "ctrl+b", "," }, .move_tab_previous),
        try .parse(&.{ "ctrl+b", "." }, .move_tab_next),
    };
}

fn requestDraw(
    io: Io,
    select: *Io.Select(ClientEvent),
    pacer: *pace.Pacer,
    draw_pending: *bool,
    draw_due_ns: *u64,
    pending_updates: *usize,
    metrics: *ClientMetrics,
) !void {
    pending_updates.* += 1;
    if (comptime diagnostics.enabled)
        metrics.max_pending_updates = @max(metrics.max_pending_updates, pending_updates.*);
    if (draw_pending.*) return;
    const now_ns = monotonic(io);
    const deadline_ns = pacer.waitUntil(now_ns) orelse now_ns;
    if (deadline_ns != now_ns) pacer.noteThrottled();
    draw_pending.* = true;
    draw_due_ns.* = deadline_ns;
    select.concurrent(.draw, waitToDraw, .{ io, deadline_ns }) catch |err| {
        draw_pending.* = false;
        return err;
    };
}

fn resizeAttached(
    io: Io,
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    model: *multiplexer.Model,
    area: ui.Rect,
) !void {
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (!pane.attached) continue;
        const size = model.contentSize(pane.id, area) orelse continue;
        const payload = try schema.encodePaneResize(send_buffer, .{
            .pane_id = pane.id,
            .size = size,
        });
        try connection.send(io, payload);
    }
}

fn scheduleInputTimers(
    io: Io,
    select: *Io.Select(ClientEvent),
    router: *const InputRouter,
    input_pending: *bool,
    binding_pending: *bool,
) !void {
    if (!input_pending.*) {
        if (router.inputDeadline()) |deadline| {
            input_pending.* = true;
            select.concurrent(.input_timeout, waitUntil, .{ io, deadline }) catch |err| {
                input_pending.* = false;
                return err;
            };
        }
    }
    if (!binding_pending.*) {
        if (router.bindingDeadline()) |deadline| {
            binding_pending.* = true;
            select.concurrent(.binding_timeout, waitUntil, .{ io, deadline }) catch |err| {
                binding_pending.* = false;
                return err;
            };
        }
    }
}

fn waitUntil(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn waitResize(io: Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

fn receive(io: Io, connection: *core.transport.SocketChannel, buffer: []u8) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn presentModel(
    io: Io,
    screen: *term.Screen,
    writer: *Io.Writer,
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    metrics: *ClientMetrics,
    tabs: *const tabs_mod.Model,
    model: *multiplexer.Model,
    view: *client_view.State,
) !u64 {
    const compose_started = diagnostics.now(io);
    const composed = try model.render(screen, view.workbench());
    const chrome = try view.render(screen, tabs, model, composed.full);
    if (comptime diagnostics.enabled) {
        metrics.composed_panes += composed.panes;
        metrics.composed_cells += composed.cells;
        metrics.composed_damage_cells += composed.damaged_cells;
        metrics.chrome_scanned_cells += chrome.scanned;
        metrics.chrome_damaged_cells += chrome.damaged;
        metrics.full_compositions += @intFromBool(composed.full);
        metrics.compose.observe(diagnostics.elapsed(compose_started, diagnostics.now(io)));
    }
    try flushScreen(io, screen, writer, metrics);
    const presented_ns = monotonic(io);
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        if (!pane.attached or pane.pending_frame_id == 0) continue;
        const ack_started = diagnostics.now(io);
        const ack = try schema.encodeFrameAck(send_buffer, .{
            .pane_id = pane.id,
            .frame_id = pane.pending_frame_id,
        });
        try connection.send(io, ack);
        pane.pending_frame_id = 0;
        if (comptime diagnostics.enabled)
            metrics.ack_send.observe(diagnostics.elapsed(ack_started, diagnostics.now(io)));
    }
    return presented_ns;
}

fn observePresentation(
    metrics: *ClientMetrics,
    previous_ns: *?u64,
    presented_ns: u64,
    paced: bool,
) void {
    if (comptime diagnostics.enabled) {
        if (paced) {
            if (previous_ns.*) |previous|
                metrics.paced_interval.observe(presented_ns -| previous);
        }
    }
    previous_ns.* = presented_ns;
}

fn flushScreen(
    io: Io,
    screen: *term.Screen,
    writer: *Io.Writer,
    metrics: *ClientMetrics,
) !void {
    const started = diagnostics.now(io);
    const stats = try screen.flush(writer);
    if (comptime diagnostics.enabled) {
        metrics.flushes += 1;
        metrics.scanned_cells += stats.scanned;
        metrics.flushed_cells += stats.cells;
        metrics.flushed_bytes += stats.bytes;
        metrics.flush.observe(diagnostics.elapsed(started, diagnostics.now(io)));
    }
}

fn writeDiagnostics(io: Io, sink: *diagnostics.Sink, bytes: []const u8) anyerror!void {
    try sink.write(io, bytes);
}

fn formatClientTelemetry(
    buffer: []u8,
    io: Io,
    metrics: *const ClientMetrics,
    pacer: *const pace.Pacer,
    active_tab: schema.TabId,
    tab_count: usize,
    focused_pane: schema.PaneId,
    pane_count: usize,
    pending_updates: usize,
    draw_pending: bool,
) ![]const u8 {
    const now_ns = diagnostics.now(io);
    var writer = Io.Writer.fixed(buffer);
    try writer.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"client\"," ++
        "\"active_tab\":{d},\"tab_count\":{d}," ++
        "\"focused_pane\":{d},\"pane_count\":{d},\"pending_updates\":{d}," ++
        "\"draw_pending\":{d},\"input_events\":{d},\"input_bytes\":{d}," ++
        "\"server_messages\":{d},\"server_bytes\":{d}," ++
        "\"frames\":{d},\"frame_cells\":{d},\"frame_spans\":{d}," ++
        "\"snapshots\":{d},\"composed_panes\":{d},\"composed_cells\":{d}," ++
        "\"composed_damage_cells\":{d},\"full_compositions\":{d}," ++
        "\"flushes\":{d},\"scanned_cells\":{d},\"flushed_cells\":{d}," ++
        "\"flushed_bytes\":{d},\"max_pending_updates\":{d}," ++
        "\"mouse_events\":{d},\"chrome_scanned_cells\":{d}," ++
        "\"chrome_damaged_cells\":{d}," ++
        "\"pacer_drawn\":{d},\"pacer_throttled\":{d},\"pacer_absorbed\":{d}", .{
        now_ns / std.time.ns_per_ms,
        diagnostics.elapsed(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        schema.id.raw(active_tab),
        tab_count,
        schema.id.raw(focused_pane),
        pane_count,
        pending_updates,
        @intFromBool(draw_pending),
        metrics.input_events,
        metrics.input_bytes,
        metrics.server_messages,
        metrics.server_bytes,
        metrics.frames,
        metrics.frame_cells,
        metrics.frame_spans,
        metrics.snapshots,
        metrics.composed_panes,
        metrics.composed_cells,
        metrics.composed_damage_cells,
        metrics.full_compositions,
        metrics.flushes,
        metrics.scanned_cells,
        metrics.flushed_cells,
        metrics.flushed_bytes,
        metrics.max_pending_updates,
        metrics.mouse_events,
        metrics.chrome_scanned_cells,
        metrics.chrome_damaged_cells,
        pacer.stats.drawn,
        pacer.stats.throttled,
        pacer.stats.absorbed,
    });
    try writer.print(",\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"apply_avg_us\":{d},\"apply_max_us\":{d}," ++
        "\"compose_avg_us\":{d},\"compose_max_us\":{d}," ++
        "\"ack_send_avg_us\":{d},\"ack_send_max_us\":{d}," ++
        "\"input_send_avg_us\":{d},\"input_send_max_us\":{d}," ++
        "\"flush_avg_us\":{d},\"flush_max_us\":{d}," ++
        "\"draw_late_avg_us\":{d},\"draw_late_max_us\":{d}," ++
        "\"paced_interval_avg_us\":{d},\"paced_interval_max_us\":{d}}}\n", .{
        metrics.decode.average() / std.time.ns_per_us,         metrics.decode.max_ns / std.time.ns_per_us,
        metrics.apply.average() / std.time.ns_per_us,          metrics.apply.max_ns / std.time.ns_per_us,
        metrics.compose.average() / std.time.ns_per_us,        metrics.compose.max_ns / std.time.ns_per_us,
        metrics.ack_send.average() / std.time.ns_per_us,       metrics.ack_send.max_ns / std.time.ns_per_us,
        metrics.input_send.average() / std.time.ns_per_us,     metrics.input_send.max_ns / std.time.ns_per_us,
        metrics.flush.average() / std.time.ns_per_us,          metrics.flush.max_ns / std.time.ns_per_us,
        metrics.draw_lateness.average() / std.time.ns_per_us,  metrics.draw_lateness.max_ns / std.time.ns_per_us,
        metrics.paced_interval.average() / std.time.ns_per_us, metrics.paced_interval.max_ns / std.time.ns_per_us,
    });
    return buffer[0..writer.end];
}

fn waitToDraw(io: Io, deadline_ns: u64) anyerror!void {
    const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
    try deadline.wait(io);
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

fn terminalSize(tty: *const platform.Tty) schema.TerminalSize {
    const size = tty.size();
    return .{
        .cols = if (size.cols == 0) 80 else size.cols,
        .rows = if (size.rows == 0) 24 else size.rows,
    };
}

fn rectSize(rect: ui.Rect) ?schema.TerminalSize {
    if (rect.w == 0 or rect.h == 0) return null;
    return .{ .cols = rect.w, .rows = rect.h };
}

fn nextRequestId(next: *u64) !schema.RequestId {
    if (next.* == 0 or next.* == std.math.maxInt(u64))
        return error.RequestIdExhausted;
    const value = next.*;
    next.* += 1;
    return @enumFromInt(value);
}

fn exitCode(message: schema.PaneExited) u8 {
    return switch (message.kind) {
        .exited => @intCast(@min(message.value, std.math.maxInt(u8))),
        .signaled => @intCast(@min(128 + message.value, std.math.maxInt(u8))),
    };
}

test "signal exits use the shell status convention" {
    try std.testing.expectEqual(@as(u8, 137), exitCode(.{
        .pane_id = @enumFromInt(1),
        .kind = .signaled,
        .value = 9,
    }));
}

test "configured action names cover multiplexer operations" {
    try std.testing.expectEqual(Action.detach, try Action.parse("detach"));
    try std.testing.expectEqual(Action.split_horizontal, try Action.parse("split-horizontal"));
    try std.testing.expectEqual(Action.close_pane, try Action.parse("close-pane"));
    try std.testing.expectEqual(Action.toggle_sidebar, try Action.parse("toggle-sidebar"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}

test "default bindings compile without ambiguous prefixes" {
    var bindings = try defaultBindings();
    _ = try InputRouter.init(&bindings);
}

test "pending attachments are removed by request id" {
    var pending: PendingAttachments = .{};
    try pending.add(.{ .request_id = @enumFromInt(7), .pane_id = @enumFromInt(3) });
    try std.testing.expectEqual(
        @as(schema.PaneId, @enumFromInt(3)),
        pending.take(@enumFromInt(7)).?,
    );
    try std.testing.expect(pending.take(@enumFromInt(7)) == null);
}
