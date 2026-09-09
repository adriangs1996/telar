//! Per-client projection and acknowledgement of one pane's cell state.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const telemetry = @import("../observability/root.zig").telemetry;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const RuntimeMetrics = telemetry.RuntimeMetrics;

pub const Preparation = struct {
    io: Io,
    buffer: []u8,
    pane: *Pane,
    force_snapshot: bool,
    /// Projects every row instead of trusting emulator damage, then diffs the
    /// result against the acknowledged cells. A moved viewport needs this: the
    /// emulator marks nothing dirty when only the visible window changes.
    force_projection: bool = false,
    metrics: *RuntimeMetrics,
};

pub const Sync = struct {
    acknowledged: core.ui.Buffer,
    acknowledged_cursor: schema.frame.Cursor = .{},
    acknowledged_mouse: schema.frame.Mouse = .{},
    acknowledged_input_modes: schema.frame.InputModes = .{},
    acknowledged_pointer_shape: schema.frame.PointerShape = .default,
    acknowledged_scroll: schema.frame.Scroll = .{ .total_rows = 1, .offset = 0 },
    projected: core.ui.Buffer,
    projected_damage: []bool,
    projected_state: vt.RenderState = .empty,
    viewport_pin: ?*vt.Pin = null,
    viewport_screen: vt.ScreenSet.Key,
    observed_revision: u64 = 0,
    next_frame_id: u64 = 1,
    acknowledged_frame_id: u64 = 0,
    /// The id the next patch is diffed against: the newest frame sent, acked
    /// or not, because the client applies frames in order.
    last_sent_frame_id: u64 = 0,
    /// Frames sent and not yet acknowledged, oldest first. A second frame
    /// may follow the first before its acknowledgement returns, so a burst of
    /// output does not pay a client paint and two socket hops per frame.
    outstanding: [frame_window]Outstanding = undefined,
    outstanding_count: u8 = 0,
    snapshot_pending: bool = true,
    /// The client viewport moved since the last projection. The next frame
    /// projects every row and sends the difference as a patch, not a snapshot.
    viewport_moved: bool = false,
    gpa: std.mem.Allocator,

    pub const frame_window = 2;

    const Outstanding = struct {
        frame_id: u64,
        sent_ns: u64,
    };

    pub fn init(gpa: std.mem.Allocator, pane: *Pane) !Sync {
        var acknowledged = try core.ui.Buffer.init(gpa, pane.screen.w, pane.screen.h);
        errdefer acknowledged.deinit();
        var projected = try core.ui.Buffer.init(gpa, pane.screen.w, pane.screen.h);
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

    pub fn deinit(sync: *Sync, pane: *Pane) void {
        sync.clearViewport(pane);
        sync.projected_state.deinit(sync.gpa);
        sync.gpa.free(sync.projected_damage);
        sync.projected.deinit();
        sync.acknowledged.deinit();
    }

    pub fn resizeIfNeeded(sync: *Sync, pane: *Pane) !bool {
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
        sync.outstanding_count = 0;
        sync.snapshot_pending = true;
        return true;
    }

    fn syncViewportScreen(sync: *Sync, pane: *Pane) void {
        const active_key = pane.terminal.screens.active_key;
        if (sync.viewport_screen == active_key) {
            return;
        }
        sync.clearViewport(pane);
        sync.viewport_screen = active_key;
    }

    pub fn clearViewport(sync: *Sync, pane: *Pane) void {
        if (sync.viewport_pin) |pin| {
            const screen = pane.terminal.screens.get(sync.viewport_screen).?;
            screen.scroll(.{ .active = {} });
            screen.pages.untrackPin(pin);
        }
        sync.viewport_pin = null;
    }

    /// Moves this client's viewport without leaving the shared terminal
    /// scrolled. Returns whether the effective offset changed. On allocation
    /// failure, the previous client viewport and projection state are
    /// preserved. A changed viewport marks the next frame as a full projection
    /// diffed against the acknowledged cells; it never schedules a snapshot.
    ///
    /// ```zig
    /// const changed = try sync.setViewport(pane, requested_offset);
    /// ```
    pub fn setViewport(sync: *Sync, pane: *Pane, requested: u32) !bool {
        const terminal_allocations = diagnostics.enterTerminalAllocations();
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

        sync.viewport_moved = true;
        return true;
    }

    pub fn requestSnapshot(sync: *Sync) void {
        sync.snapshot_pending = true;
    }

    /// The oldest unacknowledged frame, or zero when every sent frame was
    /// acknowledged. Example: `if (sync.outstandingFrameId() != 0) wait();`.
    pub fn outstandingFrameId(sync: *const Sync) u64 {
        return if (sync.outstanding_count != 0) sync.outstanding[0].frame_id else 0;
    }

    /// Whether the window is full and the next dependent patch must wait
    /// for an acknowledgement. Example: `if (sync.windowFull()) return null;`.
    pub fn windowFull(sync: *const Sync) bool {
        return sync.outstanding_count == frame_window;
    }

    /// When the newest outstanding frame left, for latency measurement.
    /// Example: `const sent_ns = sync.lastSentNs().?;`.
    pub fn lastSentNs(sync: *const Sync) ?u64 {
        if (sync.outstanding_count == 0) {
            return null;
        }
        return sync.outstanding[sync.outstanding_count - 1].sent_ns;
    }

    /// Accepts an acknowledgement for any outstanding frame. The client
    /// applies frames in order and acknowledges the newest it presented, so
    /// every older outstanding frame is acknowledged with it.
    ///
    /// ```zig
    /// const elapsed = sync.acknowledge(frame_id, now_ns) orelse return;
    /// ```
    pub fn acknowledge(sync: *Sync, frame_id: u64, now_ns: u64) ?u64 {
        const index = for (sync.outstanding[0..sync.outstanding_count], 0..) |outstanding, index| {
            if (outstanding.frame_id == frame_id) {
                break index;
            }
        } else return null;

        const elapsed = diagnostics.elapsed(sync.outstanding[index].sent_ns, now_ns);
        const remaining = sync.outstanding_count - (index + 1);
        std.mem.copyForwards(Outstanding, sync.outstanding[0..remaining], sync.outstanding[index + 1 .. sync.outstanding_count]);
        sync.outstanding_count = @intCast(remaining);
        sync.acknowledged_frame_id = frame_id;
        return elapsed;
    }

    fn recordSent(sync: *Sync, frame_id: u64, sent_ns: u64) void {
        std.debug.assert(sync.outstanding_count < frame_window);
        sync.outstanding[sync.outstanding_count] = .{ .frame_id = frame_id, .sent_ns = sent_ns };
        sync.outstanding_count += 1;
        sync.last_sent_frame_id = frame_id;
    }

    const Projection = struct {
        buffer: *const core.ui.Buffer,
        damaged_rows: []const bool,
        cursor: schema.frame.Cursor,
        scroll: schema.frame.Scroll,
    };

    pub fn project(sync: *Sync, pane: *Pane, force: bool) !Projection {
        sync.syncViewportScreen(pane);
        const screen = pane.terminal.screens.active;
        if (sync.viewport_pin) |pin| {
            if (pin.garbage) {
                pin.garbage = false;
            }
            screen.scroll(.{ .pin = pin.* });
            defer screen.scroll(.{ .active = {} });
            {
                const terminal_allocations = diagnostics.enterTerminalAllocations();
                defer terminal_allocations.restore();
                try sync.projected_state.update(sync.gpa, &pane.terminal);
            }
            _ = pane_mod.blit.blit(.{
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

        if (force) {
            @memset(sync.projected_damage, true);
        }

        return .{
            .buffer = &pane.screen,
            .damaged_rows = if (force) sync.projected_damage else pane.damaged_rows,
            .cursor = pane.cursor,
            .scroll = scrollState(screen.pages.scrollbar()),
        };
    }

    fn scrollState(value: anytype) schema.frame.Scroll {
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
        const started = diagnostics.now(io);
        if (pane.render_pending) {
            try pane.render(false);
        }
        const projection = try sync.project(pane, force_snapshot or preparation.force_projection);
        const source = projection.buffer;
        var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
        var snapshot = force_snapshot;
        const diff = if (snapshot)
            pane_mod.damage.Diff{}
        else
            pane_mod.damage.collectSpans(.{
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
            span_storage[0] = .{ .start = 0, .cells = source.cells };
            span_count = 1;
        }

        const frame_id = sync.next_frame_id;
        sync.next_frame_id += 1;
        const payload = try schema.encodePaneFrame(buffer, .{
            .pane_id = pane.id,
            .frame_id = frame_id,
            .base_frame_id = if (snapshot) 0 else sync.last_sent_frame_id,
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
        if (snapshot) {
            // A snapshot supersedes every patch still in flight; their
            // acknowledgements arrive as stale.
            sync.outstanding_count = 0;
        }
        sync.recordSent(frame_id, diagnostics.now(io));
        if (comptime diagnostics.enabled) {
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
            metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
        }
        return payload;
    }

    fn observeProjection(sync: *Sync, pane: *const Pane, projection: Projection) void {
        if (projection.damaged_rows.ptr == sync.projected_damage.ptr) {
            @memset(sync.projected_damage, false);
        }

        sync.viewport_moved = false;
        sync.observed_revision = pane.cell_revision;
    }
};

test "viewport pin allocation failure restores the shared screen and sync state" {
    const PaneFixture = @import("../tests/support.zig").PaneFixture;

    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.pane.ingest(
        std.testing.io,
        "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n",
    );
    try fixture.pane.render(false);

    var held_syncs: [64]Sync = undefined;
    var held_count: usize = 0;
    defer for (held_syncs[0..held_count]) |*sync| sync.deinit(fixture.pane);

    fixture.failNextPaneAllocation();
    var failure_observed = false;
    for (&held_syncs) |*sync| {
        sync.* = try Sync.init(std.testing.allocator, fixture.pane);
        sync.snapshot_pending = false;

        const changed = sync.setViewport(fixture.pane, 0) catch |err| {
            if (err != error.OutOfMemory) {
                sync.deinit(fixture.pane);
                return err;
            }

            const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
            try std.testing.expect(sync.viewport_pin == null);
            try std.testing.expect(!sync.snapshot_pending);
            try std.testing.expect(scrollbar.offset + scrollbar.len >= scrollbar.total);
            sync.deinit(fixture.pane);
            failure_observed = true;
            break;
        };

        try std.testing.expect(changed);
        held_count += 1;
    }

    const scrollbar = fixture.pane.terminal.screens.active.pages.scrollbar();
    try std.testing.expect(failure_observed);
    try std.testing.expect(fixture.pane_allocator.has_induced_failure);
    try std.testing.expect(scrollbar.offset + scrollbar.len >= scrollbar.total);
}
