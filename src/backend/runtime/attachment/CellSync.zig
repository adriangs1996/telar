const BufferType = @import("telar-core").Buffer;
const CursorType = @import("telar-core").Cursor;
const MouseType = @import("telar-core").Mouse;
const InputModesType = @import("telar-core").InputModes;
const PointerShapeType = @import("telar-core").PointerShape;
const ScrollType = @import("telar-core").Scroll;
const vt = @import("ghostty-vt");
const Outstanding = @import("Outstanding.zig");
const std = @import("std");
const PaneType = @import("../../pane/Pane.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const enterTerminalAllocations_module = @import("telar-core").enterTerminalAllocations;
const elapsed_module = @import("telar-core").elapsed;
const Projection = @import("Projection.zig");
const blit_module = @import("../../pane/blit.zig");
const Preparation = @import("Preparation.zig");
const now_module = @import("telar-core").now;
const max_span_count_module = @import("telar-core").max_span_count;
const SpanType = @import("telar-core").Span;
const DiffType = @import("../../pane/Diff.zig");
const damage_module = @import("../../pane/damage.zig");
const enabled_module = @import("telar-core").enabled;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const Sync = @This();

acknowledged: BufferType,
acknowledged_cursor: CursorType = .{},
acknowledged_mouse: MouseType = .{},
acknowledged_input_modes: InputModesType = .{},
acknowledged_pointer_shape: PointerShapeType = .default,
acknowledged_scroll: ScrollType = .{ .total_rows = 1, .offset = 0 },
projected: BufferType,
projected_damage: []bool,
projected_state: vt.RenderState = .empty,
viewport_pin: ?*vt.Pin = null,
viewport_screen: vt.ScreenSet.Key,
observed_revision: u64 = 0,
next_frame_id: u64 = 1,
acknowledged_frame_id: u64 = 0,
outstanding: ?Outstanding = null,
snapshot_pending: bool = true,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, pane: *PaneType) !Sync {
    var acknowledged = try BufferType.init(gpa, pane.screen.w, pane.screen.h);
    errdefer acknowledged.deinit();
    var projected = try BufferType.init(gpa, pane.screen.w, pane.screen.h);
    errdefer projected.deinit();
    const projected_damage = try gpa.alloc(bool, pane.screen.h);
    errdefer gpa.free(projected_damage);
    @memset(projected_damage, false);
    return .{
        .acknowledged = acknowledged,
        .projected = projected,
        .projected_damage = projected_damage,
        .viewport_screen = pane.terminal.screens.active_key,
        .gpa = gpa,
    };
}

pub fn deinit(sync: *Sync, pane: *PaneType) void {
    sync.clearViewport(pane);
    sync.projected_state.deinit(sync.gpa);
    sync.gpa.free(sync.projected_damage);
    sync.projected.deinit();
    sync.acknowledged.deinit();
}

pub fn resizeIfNeeded(sync: *Sync, pane: *PaneType) !bool {
    if (sync.acknowledged.w == pane.screen.w and
        sync.acknowledged.h == pane.screen.h)
    {
        return false;
    }
    try sync.acknowledged.resize(pane.screen.w, pane.screen.h);
    try pane_mod.resizeScreenStorage(.{
        .gpa = sync.gpa,
        .screen = &sync.projected,
        .damaged_rows = &sync.projected_damage,
        .cols = pane.screen.w,
        .rows = pane.screen.h,
    });
    sync.outstanding = null;
    sync.snapshot_pending = true;
    return true;
}

fn syncViewportScreen(sync: *Sync, pane: *PaneType) void {
    const active_key = pane.terminal.screens.active_key;
    if (sync.viewport_screen == active_key) {
        return;
    }
    sync.clearViewport(pane);
    sync.viewport_screen = active_key;
}

pub fn clearViewport(sync: *Sync, pane: *PaneType) void {
    if (sync.viewport_pin) |pin| {
        const screen = pane.terminal.screens.get(sync.viewport_screen).?;
        screen.scroll(.{ .active = {} });
        screen.pages.untrackPin(pin);
    }
    sync.viewport_pin = null;
}

/// Moves this client's viewport without leaving the shared terminal
/// scrolled. Returns whether the effective offset changed. On allocation
/// failure, the previous client viewport and snapshot state are preserved.
///
/// ```zig
/// const changed = try sync.setViewport(pane, requested_offset);
/// ```
pub fn setViewport(sync: *Sync, pane: *PaneType, requested: u32) !bool {
    const terminal_allocations = enterTerminalAllocations_module();
    defer terminal_allocations.restore();

    sync.syncViewportScreen(pane);
    const screen = pane.terminal.screens.active;
    if (sync.viewport_pin) |pin| {
        screen.scroll(.{ .pin = pin.* });
    } else {
        screen.scroll(.{ .active = {} });
    }

    const current_offset = screen.pages.scrollbar().offset;
    screen.scroll(.{ .row = requested });
    defer screen.scroll(.{ .active = {} });

    const scrollbar = screen.pages.scrollbar();
    if (scrollbar.offset == current_offset) {
        return false;
    }

    if (scrollbar.offset + scrollbar.len >= scrollbar.total) {
        sync.clearViewport(pane);
    } else {
        const top = screen.pages.pin(.{ .viewport = .{} }) orelse return error.ViewportUnavailable;
        if (sync.viewport_pin) |pin| {
            pin.* = top;
        } else {
            sync.viewport_pin = try screen.pages.trackPin(top);
        }
    }

    sync.snapshot_pending = true;
    return true;
}

pub fn requestSnapshot(sync: *Sync) void {
    sync.snapshot_pending = true;
}

pub fn outstandingFrameId(sync: *const Sync) u64 {
    return if (sync.outstanding) |outstanding| outstanding.frame_id else 0;
}

pub fn hasOutstanding(sync: *const Sync) bool {
    return sync.outstanding != null;
}

pub fn acknowledge(sync: *Sync, frame_id: u64, now_ns: u64) ?u64 {
    const outstanding = sync.outstanding orelse return null;
    if (outstanding.frame_id != frame_id) {
        return null;
    }
    sync.acknowledged_frame_id = frame_id;
    sync.outstanding = null;
    return elapsed_module(outstanding.sent_ns, now_ns);
}

pub fn project(sync: *Sync, pane: *PaneType, force: bool) !Projection {
    sync.syncViewportScreen(pane);
    const screen = pane.terminal.screens.active;
    if (sync.viewport_pin) |pin| {
        if (pin.garbage) {
            pin.garbage = false;
        }
        screen.scroll(.{ .pin = pin.* });
        defer screen.scroll(.{ .active = {} });
        {
            const terminal_allocations = enterTerminalAllocations_module();
            defer terminal_allocations.restore();
            try sync.projected_state.update(sync.gpa, &pane.terminal);
        }
        _ = blit_module.blit(.{
            .buffer = &sync.projected,
            .area = sync.projected.area(),
            .terminal = &pane.terminal,
            .state = &sync.projected_state,
            .options = .{ .force = force, .damaged_rows = sync.projected_damage },
        });
        return .{
            .buffer = &sync.projected,
            .damaged_rows = sync.projected_damage,
            .cursor = .{},
            .scroll = scrollState(screen.pages.scrollbar()),
        };
    }
    return .{
        .buffer = &pane.screen,
        .damaged_rows = pane.damaged_rows,
        .cursor = pane.cursor,
        .scroll = scrollState(screen.pages.scrollbar()),
    };
}

fn scrollState(value: anytype) ScrollType {
    return .{
        .total_rows = @intCast(@min(value.total, std.math.maxInt(u32))),
        .offset = @intCast(@min(value.offset, std.math.maxInt(u32))),
    };
}

/// Encodes the next cell projection without allocating and retains the
/// exact baseline needed to acknowledge it later.
///
/// ```zig
/// const payload = try sync.prepare(.{ .io = io, .buffer = buffer, .pane = pane, .force_snapshot = false, .metrics = metrics });
/// ```
pub fn prepare(sync: *Sync, preparation: Preparation) !?[]const u8 {
    const io = preparation.io;
    const buffer = preparation.buffer;
    const pane = preparation.pane;
    const force_snapshot = preparation.force_snapshot;
    const metrics = preparation.metrics;

    if (!force_snapshot and pane.holdFrames(io)) {
        return null;
    }
    const started = now_module(io);
    if (pane.render_pending) {
        try pane.render(false);
    }
    const projection = try sync.project(pane, force_snapshot);
    const source = projection.buffer;
    var span_storage: [max_span_count_module]SpanType = undefined;
    var snapshot = force_snapshot;
    const diff = if (snapshot)
        DiffType{}
    else
        damage_module.collectSpans(.{
            .current = source.cells,
            .acknowledged = sync.acknowledged.cells,
            .cols = source.w,
            .damaged_rows = projection.damaged_rows,
        }, &span_storage);
    var span_count = diff.span_count;
    snapshot = snapshot or diff.snapshot_required;

    const cursor_changed = !std.meta.eql(projection.cursor, sync.acknowledged_cursor);
    const mouse_changed = !std.meta.eql(pane.mouse, sync.acknowledged_mouse);
    const input_modes_changed = !std.meta.eql(
        pane.input_modes,
        sync.acknowledged_input_modes,
    );
    const pointer_changed = pane.pointer_shape != sync.acknowledged_pointer_shape;
    const scroll_changed = !std.meta.eql(projection.scroll, sync.acknowledged_scroll);
    if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed and
        !input_modes_changed and !pointer_changed and !scroll_changed)
    {
        sync.observeProjection(pane, projection);

        if (comptime enabled_module) {
            metrics.noop_frames += 1;
            metrics.damaged_rows += diff.damaged_rows;
            metrics.diff_scanned_cells += diff.scanned_cells;
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
            metrics.encode.observe(elapsed_module(started, now_module(io)));
        }
        return null;
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = source.cells };
        span_count = 1;
    }

    const frame_id = sync.next_frame_id;
    sync.next_frame_id += 1;
    const payload = try encodePaneFrame_module(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else sync.acknowledged_frame_id,
        .cols = source.w,
        .rows = source.h,
        .cursor = projection.cursor,
        .mouse = pane.mouse,
        .input_modes = pane.input_modes,
        .pointer_shape = pane.pointer_shape,
        .scroll = projection.scroll,
        .spans = span_storage[0..span_count],
    });
    if (snapshot) {
        @memcpy(sync.acknowledged.cells, source.cells);
    } else {
        for (span_storage[0..span_count]) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(sync.acknowledged.cells[start..][0..span.cells.len], span.cells);
        }
    }
    sync.acknowledged_cursor = projection.cursor;
    sync.acknowledged_mouse = pane.mouse;
    sync.acknowledged_input_modes = pane.input_modes;
    sync.acknowledged_pointer_shape = pane.pointer_shape;
    sync.acknowledged_scroll = projection.scroll;
    sync.observeProjection(pane, projection);
    sync.outstanding = .{ .frame_id = frame_id, .sent_ns = now_module(io) };
    if (comptime enabled_module) {
        var cell_count: u64 = 0;
        for (span_storage[0..span_count]) |span| cell_count += span.cells.len;
        metrics.frames += 1;
        metrics.frame_bytes += payload.len;
        metrics.frame_cells += cell_count;
        metrics.frame_spans += span_count;
        if (snapshot) {
            metrics.snapshots += 1;
        }
        if (!snapshot and span_count == 0) {
            metrics.cursor_only_frames += 1;
        }
        metrics.damaged_rows += diff.damaged_rows;
        metrics.diff_scanned_cells += diff.scanned_cells;
        if (!snapshot) {
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
        }
        metrics.encode.observe(elapsed_module(started, now_module(io)));
    }
    return payload;
}

fn observeProjection(sync: *Sync, pane: *const PaneType, projection: Projection) void {
    if (projection.buffer == &sync.projected) {
        @memset(sync.projected_damage, false);
    }

    sync.observed_revision = pane.cell_revision;
}
