//! Per-client projection and acknowledgement of one pane's cell state.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const telemetry = @import("../telemetry.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const RuntimeMetrics = telemetry.RuntimeMetrics;

pub const Sync = struct {
    acknowledged: core.ui.Buffer,
    acknowledged_cursor: schema.frame.Cursor = .{},
    acknowledged_mouse: schema.frame.Mouse = .{},
    acknowledged_input_modes: schema.frame.InputModes = .{},
    acknowledged_scroll: schema.frame.Scroll = .{ .total_rows = 1, .offset = 0 },
    projected: core.ui.Buffer,
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
        try pane_mod.resizeScreenStorage(
            sync.gpa,
            &sync.projected,
            &sync.projected_damage,
            pane.screen.w,
            pane.screen.h,
        );
        sync.outstanding = null;
        sync.snapshot_pending = true;
        return true;
    }

    fn syncViewportScreen(sync: *Sync, pane: *Pane) void {
        const active_key = pane.terminal.screens.active_key;
        if (sync.viewport_screen == active_key) return;
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

    pub fn setViewport(sync: *Sync, pane: *Pane, requested: u32) !void {
        const terminal_allocations = diagnostics.enterTerminalAllocations();
        defer terminal_allocations.restore();
        sync.syncViewportScreen(pane);
        const screen = pane.terminal.screens.active;
        if (sync.viewport_pin) |pin|
            screen.scroll(.{ .pin = pin.* })
        else
            screen.scroll(.{ .active = {} });
        screen.scroll(.{ .row = requested });
        const scrollbar = screen.pages.scrollbar();
        if (scrollbar.offset + scrollbar.len >= scrollbar.total) {
            screen.scroll(.{ .active = {} });
            sync.clearViewport(pane);
        } else {
            const top = screen.pages.pin(.{ .viewport = .{} }).?;
            if (sync.viewport_pin) |pin|
                pin.* = top
            else
                sync.viewport_pin = try screen.pages.trackPin(top);
            screen.scroll(.{ .active = {} });
        }
        sync.snapshot_pending = true;
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
        if (outstanding.frame_id != frame_id) return null;
        sync.acknowledged_frame_id = frame_id;
        sync.outstanding = null;
        return diagnostics.elapsed(outstanding.sent_ns, now_ns);
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
            if (pin.garbage) pin.garbage = false;
            screen.scroll(.{ .pin = pin.* });
            defer screen.scroll(.{ .active = {} });
            {
                const terminal_allocations = diagnostics.enterTerminalAllocations();
                defer terminal_allocations.restore();
                try sync.projected_state.update(sync.gpa, &pane.terminal);
            }
            _ = pane_mod.blit.blit(
                &sync.projected,
                sync.projected.area(),
                &pane.terminal,
                &sync.projected_state,
                .{ .force = force, .damaged_rows = sync.projected_damage },
            );
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

    fn scrollState(value: anytype) schema.frame.Scroll {
        return .{
            .total_rows = @intCast(@min(value.total, std.math.maxInt(u32))),
            .offset = @intCast(@min(value.offset, std.math.maxInt(u32))),
        };
    }

    pub fn prepare(
        sync: *Sync,
        io: Io,
        buffer: []u8,
        pane: *Pane,
        force_snapshot: bool,
        metrics: *RuntimeMetrics,
    ) !?[]const u8 {
        if (!force_snapshot and pane.holdFrames(io)) return null;
        const started = diagnostics.now(io);
        if (pane.render_pending) try pane.render(false);
        const projection = try sync.project(pane, force_snapshot);
        const source = projection.buffer;
        var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
        var snapshot = force_snapshot;
        const diff = if (snapshot)
            pane_mod.damage.Diff{}
        else
            pane_mod.damage.collectSpans(
                source.cells,
                sync.acknowledged.cells,
                source.w,
                projection.damaged_rows,
                &span_storage,
            );
        var span_count = diff.span_count;
        snapshot = snapshot or diff.snapshot_required;

        const cursor_changed = !std.meta.eql(projection.cursor, sync.acknowledged_cursor);
        const mouse_changed = !std.meta.eql(pane.mouse, sync.acknowledged_mouse);
        const input_modes_changed = !std.meta.eql(
            pane.input_modes,
            sync.acknowledged_input_modes,
        );
        const scroll_changed = !std.meta.eql(projection.scroll, sync.acknowledged_scroll);
        if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed and
            !input_modes_changed and !scroll_changed)
        {
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
            .base_frame_id = if (snapshot) 0 else sync.acknowledged_frame_id,
            .cols = source.w,
            .rows = source.h,
            .cursor = projection.cursor,
            .mouse = pane.mouse,
            .input_modes = pane.input_modes,
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
        sync.acknowledged_scroll = projection.scroll;
        if (projection.buffer == &sync.projected) @memset(sync.projected_damage, false);
        sync.observed_revision = pane.cell_revision;
        sync.outstanding = .{ .frame_id = frame_id, .sent_ns = diagnostics.now(io) };
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
};
