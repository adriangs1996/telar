const TextMetadataCapture = @import("../../pane/TextMetadataCapture.zig");
const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
const pane_mod = @import("../../pane/pane_namespace.zig");
const blit_module = @import("../../pane/blit.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Diff = @import("../../pane/Diff.zig");
const damage_module = @import("../../pane/damage.zig");
const Sync = @This();

acknowledged: core.Buffer,
acknowledged_text_revision: u64 = 0,
acknowledged_text_projected: bool = false,
acknowledged_cursor: core.Cursor = .{},
acknowledged_mouse: core.Mouse = .{},
acknowledged_input_modes: core.InputModes = .{},
acknowledged_pointer_shape: core.PointerShape = .default,
acknowledged_scroll: core.Scroll = .{ .total_rows = 1, .offset = 0 },
projected: core.Buffer,
projected_damage: []bool,
projected_state: vt.RenderState = .empty,
projected_text_metadata: TextMetadataCapture,
viewport_pin: ?*vt.Pin = null,
viewport_screen: vt.ScreenSet.Key,
observed_revision: u64 = 0,
next_frame_id: u64 = 1,
acknowledged_frame_id: u64 = 0,
outstanding: ?Outstanding = null,
snapshot_pending: bool = true,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Sync {
    var acknowledged = try core.Buffer.init(gpa, pane.screen.w, pane.screen.h);
    errdefer acknowledged.deinit();
    var projected = try core.Buffer.init(gpa, pane.screen.w, pane.screen.h);
    errdefer projected.deinit();
    const projected_damage = try gpa.alloc(bool, pane.screen.h);
    errdefer gpa.free(projected_damage);
    @memset(projected_damage, false);
    const projected_text_metadata = try TextMetadataCapture.init(gpa, pane.screen.h);
    return .{
        .projected_text_metadata = projected_text_metadata,
        .acknowledged = acknowledged,
        .projected = projected,
        .projected_damage = projected_damage,
        .viewport_screen = pane.terminal.screens.active_key,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Sync, pane: *Pane) void {
    self.clearViewport(pane);
    self.projected_text_metadata.deinit(self.gpa);
    self.projected_state.deinit(self.gpa);
    self.gpa.free(self.projected_damage);
    self.projected.deinit();
    self.acknowledged.deinit();
}

pub fn resizeIfNeeded(self: *Sync, pane: *Pane) !bool {
    if (self.acknowledged.w == pane.screen.w and
        self.acknowledged.h == pane.screen.h)
    {
        return false;
    }
    try self.acknowledged.resize(pane.screen.w, pane.screen.h);
    try pane_mod.resizeScreenStorage(.{
        .gpa = self.gpa,
        .screen = &self.projected,
        .damaged_rows = &self.projected_damage,
        .cols = pane.screen.w,
        .rows = pane.screen.h,
    });
    self.outstanding = null;
    self.snapshot_pending = true;
    return true;
}

fn syncViewportScreen(self: *Sync, pane: *Pane) void {
    const active_key = pane.terminal.screens.active_key;
    if (self.viewport_screen == active_key) {
        return;
    }
    self.clearViewport(pane);
    self.viewport_screen = active_key;
}

pub fn clearViewport(self: *Sync, pane: *Pane) void {
    if (self.viewport_pin) |pin| {
        const screen = pane.terminal.screens.get(self.viewport_screen).?;
        screen.scroll(.{ .active = {} });
        screen.pages.untrackPin(pin);
    }
    self.viewport_pin = null;
}

/// Moves this client's viewport without leaving the shared terminal
/// scrolled. Returns whether the effective offset changed. On allocation
/// failure, the previous client viewport and snapshot state are preserved.
///
/// ```zig
/// const changed = try sync.setViewport(pane, requested_offset);
/// ```
pub fn setViewport(self: *Sync, pane: *Pane, requested: u32) !bool {
    const terminal_allocations = core.enterTerminalAllocations();
    defer terminal_allocations.restore();

    self.syncViewportScreen(pane);
    const screen = pane.terminal.screens.active;
    if (self.viewport_pin) |pin| {
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
        self.clearViewport(pane);
    } else {
        const top = screen.pages.pin(.{ .viewport = .{} }) orelse return error.ViewportUnavailable;
        if (self.viewport_pin) |pin| {
            pin.* = top;
        } else {
            self.viewport_pin = try screen.pages.trackPin(top);
        }
    }

    self.snapshot_pending = true;
    return true;
}

pub fn requestSnapshot(self: *Sync) void {
    self.snapshot_pending = true;
}

pub fn outstandingFrameId(self: *const Sync) u64 {
    return if (self.outstanding) |outstanding| outstanding.frame_id else 0;
}

pub fn hasOutstanding(self: *const Sync) bool {
    return self.outstanding != null;
}

pub fn acknowledge(self: *Sync, frame_id: u64, now_ns: u64) ?u64 {
    const outstanding = self.outstanding orelse return null;
    if (outstanding.frame_id != frame_id) {
        return null;
    }
    self.acknowledged_frame_id = frame_id;
    self.outstanding = null;
    return core.elapsed(outstanding.sent_ns, now_ns);
}

pub fn project(self: *Sync, pane: *Pane, force: bool) !Projection {
    self.syncViewportScreen(pane);
    const screen = pane.terminal.screens.active;
    if (self.viewport_pin) |pin| {
        if (pin.garbage) {
            pin.garbage = false;
        }
        screen.scroll(.{ .pin = pin.* });
        defer screen.scroll(.{ .active = {} });
        {
            const terminal_allocations = core.enterTerminalAllocations();
            defer terminal_allocations.restore();
            try self.projected_state.update(self.gpa, &pane.terminal);
        }
        try self.projected_text_metadata.update(self.gpa, &self.projected_state);
        _ = blit_module.blit(.{
            .buffer = &self.projected,
            .area = self.projected.area(),
            .terminal = &pane.terminal,
            .state = &self.projected_state,
            .options = .{ .force = force, .damaged_rows = self.projected_damage },
        });
        return .{
            .buffer = &self.projected,
            .text_metadata = self.projected_text_metadata.current.view(),
            .text_revision = self.projected_text_metadata.revision,
            .damaged_rows = self.projected_damage,
            .cursor = .{},
            .scroll = scrollState(screen.pages.scrollbar()),
        };
    }
    return .{
        .buffer = &pane.screen,
        .text_metadata = pane.text_metadata.current.view(),
        .text_revision = pane.text_metadata.revision,
        .damaged_rows = pane.damaged_rows,
        .cursor = pane.cursor,
        .scroll = scrollState(screen.pages.scrollbar()),
    };
}

fn scrollState(value: anytype) core.Scroll {
    return .{
        .total_rows = @intCast(@min(value.total, std.math.maxInt(u32))),
        .offset = @intCast(@min(value.offset, std.math.maxInt(u32))),
    };
}

/// Encodes the next cell projection without allocating and retains the
/// exact baseline needed to acknowledge it later. Snapshots and patches
/// wait for synchronized redraw completion or expiry while output is live.
///
/// ```zig
/// const payload = try sync.prepare(.{ .io = io, .buffer = buffer, .pane = pane, .force_snapshot = false, .metrics = metrics });
/// ```
pub fn prepare(self: *Sync, preparation: Preparation) !?[]const u8 {
    const io = preparation.io;
    const buffer = preparation.buffer;
    const pane = preparation.pane;
    const force_snapshot = preparation.force_snapshot;
    const metrics = preparation.metrics;

    if (!pane.output_done and pane.holdFrames(io)) {
        return null;
    }
    const started = core.now(io);
    if (pane.render_pending) {
        try pane.render(false);
    }
    const projection = try self.project(pane, force_snapshot);
    const source = projection.buffer;
    var span_storage: [core.max_span_count]core.Span = undefined;
    var snapshot = force_snapshot;
    const diff = if (snapshot)
        Diff{}
    else
        damage_module.collectSpans(.{
            .current = source.cells,
            .acknowledged = self.acknowledged.cells,
            .cols = source.w,
            .damaged_rows = projection.damaged_rows,
        }, &span_storage);
    var span_count = diff.span_count;
    snapshot = snapshot or diff.snapshot_required;

    const text_projected = self.viewport_pin != null;
    const text_changed = projection.text_revision != self.acknowledged_text_revision or text_projected != self.acknowledged_text_projected;
    const cursor_changed = !std.meta.eql(projection.cursor, self.acknowledged_cursor);
    const mouse_changed = !std.meta.eql(pane.mouse, self.acknowledged_mouse);
    const input_modes_changed = !std.meta.eql(
        pane.input_modes,
        self.acknowledged_input_modes,
    );
    const pointer_changed = pane.pointer_shape != self.acknowledged_pointer_shape;
    const scroll_changed = !std.meta.eql(projection.scroll, self.acknowledged_scroll);
    if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed and
        !input_modes_changed and !pointer_changed and !scroll_changed and !text_changed)
    {
        self.observeProjection(pane, projection);

        if (comptime core.enabled) {
            metrics.noop_frames += 1;
            metrics.damaged_rows += diff.damaged_rows;
            metrics.diff_scanned_cells += diff.scanned_cells;
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
            metrics.encode.observe(core.elapsed(started, core.now(io)));
        }
        return null;
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = source.cells };
        span_count = 1;
    }

    const frame_id = self.next_frame_id;
    self.next_frame_id += 1;
    const payload = try core.encodePaneFrame(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else self.acknowledged_frame_id,
        .cols = source.w,
        .rows = source.h,
        .cursor = projection.cursor,
        .mouse = pane.mouse,
        .input_modes = pane.input_modes,
        .pointer_shape = pane.pointer_shape,
        .scroll = projection.scroll,
        .spans = span_storage[0..span_count],
        .text_metadata = if (snapshot or text_changed) projection.text_metadata else null,
    });
    if (snapshot) {
        @memcpy(self.acknowledged.cells, source.cells);
    } else {
        for (span_storage[0..span_count]) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(self.acknowledged.cells[start..][0..span.cells.len], span.cells);
        }
    }
    self.acknowledged_text_revision = projection.text_revision;
    self.acknowledged_text_projected = text_projected;
    self.acknowledged_cursor = projection.cursor;
    self.acknowledged_mouse = pane.mouse;
    self.acknowledged_input_modes = pane.input_modes;
    self.acknowledged_pointer_shape = pane.pointer_shape;
    self.acknowledged_scroll = projection.scroll;
    self.observeProjection(pane, projection);
    self.outstanding = .{ .frame_id = frame_id, .sent_ns = core.now(io) };
    if (comptime core.enabled) {
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
        metrics.encode.observe(core.elapsed(started, core.now(io)));
    }
    return payload;
}

fn observeProjection(self: *Sync, pane: *const Pane, projection: Projection) void {
    if (projection.buffer == &self.projected) {
        @memset(self.projected_damage, false);
    }

    self.observed_revision = pane.cell_revision;
}

const Preparation = struct {
    io: std.Io,
    buffer: []u8,
    pane: *Pane,
    force_snapshot: bool,
    metrics: *RuntimeMetrics,
};

const Outstanding = struct {
    frame_id: u64,
    sent_ns: u64,
};

const Projection = struct {
    buffer: *const core.Buffer,
    damaged_rows: []const bool,
    cursor: core.Cursor,
    scroll: core.Scroll,

    text_metadata: core.TextMetadataView,
    text_revision: u64,
};
