//! Offline CPU workloads. This executable does not open a native window.
const std = @import("std");
const core = @import("telar-core");
const options = @import("profile_options");
const data = @import("model");
const client = @import("telar-client");
const Renderer = @import("render/TerminalRenderer.zig");
const CellMesh = @import("render/CellMesh.zig");
const gfx = @import("gfx");
const Quad = gfx.Quad;
const Canvas = @import("widgets/Canvas.zig");
const Widget = @import("change_review/Widget.zig");
const ThreadFlow = @import("widgets/ThreadFlow.zig");
const State = @import("widgets/interaction/State.zig");

pub const telar_profile_counts = options.profile_counts;
pub const telar_profile_timing = options.profile_timing;
pub var profile_store: if (core.profiling.active) core.ProfileStore else void = if (core.profiling.active) .{} else {};

/// Run fixed CPU workloads: `telar-dod-probe > measurements.jsonl`.
pub fn main(init: std.process.Init) !void {
    defer if (comptime core.profiling.active) {
        if (init.environ_map.get("TELAR_PROFILE_DIR")) |directory| {
            profile_store.dump(init.io, directory) catch {};
        }
    };
    var buffer: [16384]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var probe: Probe = .{ .io = init.io, .gpa = init.gpa, .writer = &output.interface };
    probe.terminal_only = init.environ_map.get("DOD_TERMINAL_ONLY") != null;
    probe.agent_only = init.environ_map.get("DOD_AGENT_ONLY") != null;
    probe.terminal_mode = init.environ_map.get("DOD_MODE");
    probe.verify = init.environ_map.get("DOD_VERIFY") != null;
    if (init.environ_map.get("DOD_SAMPLES")) |value| {
        probe.sample_count = try std.fmt.parseInt(usize, value, 10);
    }
    if (init.environ_map.get("DOD_WARMUP")) |value| {
        probe.warmup_count = try std.fmt.parseInt(usize, value, 10);
    }
    if (init.environ_map.get("DOD_WARMUP_NS")) |value| {
        probe.warmup_ns = try std.fmt.parseInt(u64, value, 10);
    }
    try probe.run();
    try output.interface.flush();
}

/// Reproducible CPU preparation, separate from end-to-end native latency.
const Probe = struct {
    const iterations = 1000;
    const warmup = 200;
    const Mode = enum { retained, sparse, full, theme, resize, selection, font, two_one_active, two_all_active, cursor, focus, reattach };
    /// `repeated` stays inside the shaping cache; `distinct` gives every word its own text, as long transcripts do.
    const Transcript = enum { repeated, distinct };

    io: std.Io,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    terminal_only: bool = false,
    agent_only: bool = false,
    terminal_mode: ?[]const u8 = null,
    sample_count: ?usize = null,
    warmup_count: ?usize = null,
    warmup_ns: u64 = 0,
    verify: bool = false,

    /// Reports sizes and runs validated fixed workloads. Example: `try probe.run();`
    pub fn run(self: *Probe) !void {
        inline for (.{ core.Cell, data.Pane, data.Tabs, data.Panes, client.Client, Renderer, CellMesh, Quad.Quad, ThreadFlow, Widget, core.ProfileStore }) |T| {
            try self.writer.print("{{\"type\":\"layout\",\"name\":\"{s}\",\"size\":{d},\"alignment\":{d},\"fields\":[", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
            inline for (std.meta.fields(T), 0..) |field, index| {
                try self.writer.print("{s}{{\"name\":\"{s}\",\"offset\":{d},\"size\":{d}}}", .{ if (index == 0) "" else ",", field.name, @offsetOf(T, field.name), @sizeOf(field.type) });
            }
            try self.writer.writeAll("]}\n");
        }

        if (self.agent_only) {
            try self.conversation(.repeated);
            try self.conversation(.distinct);
            return;
        }

        for ([_]u16{ 80, 160 }) |cols| {
            inline for (std.meta.tags(Mode)) |mode| {
                if (self.terminal_mode == null or std.mem.eql(u8, self.terminal_mode.?, @tagName(mode))) {
                    try self.terminal(cols, mode);
                }
            }
        }
        if (self.terminal_only) {
            return;
        }

        for ([_]usize{ 1, 8, 64 }) |count| {
            try self.workspace(count);
        }
        try self.conversation(.repeated);
        try self.conversation(.distinct);
        for ([_]usize{ 100, 1000, 10000 }) |lines| {
            try self.review(lines);
        }
    }

    fn terminal(self: *Probe, cols: u16, mode: Mode) !void {
        const samples = self.sample_count orelse if (mode == .font) @as(usize, 10) else iterations;
        var preheat = self.warmup_count orelse if (mode == .font) @as(usize, 2) else warmup;
        var accounting = std.testing.FailingAllocator.init(self.gpa, .{});
        var renderer = Renderer.init(accounting.allocator());
        defer renderer.deinit();
        _ = try renderer.measure(.{ .width = 100, .height = 150, .scale = 1 });
        const size = try renderer.measure(.{ .width = @as(u32, cols) * renderer.metrics.cell_width + renderer.origin[0] * 2, .height = 40 * @as(u32, renderer.metrics.cell_height) + renderer.chrome.vertical() + 16, .scale = 1 });
        var pane = try data.Pane.init(accounting.allocator(), .{ .spec = .{ .pane_id = @enumFromInt(1), .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, .size = size }, .attached = true });
        defer pane.deinit();
        for (pane.buffer.cells) |*cell| {
            cell.* = .{};
            cell.bytes[0] = 'a';
        }
        pane.attachment_generation = 1;
        pane.applied_frame_id = 1;
        pane.cursor.visible = true;
        const multiple = mode == .two_one_active or mode == .two_all_active;
        var other = try data.Pane.init(accounting.allocator(), .{ .spec = .{ .pane_id = @enumFromInt(2), .location = pane.location, .size = size }, .attached = true });
        defer other.deinit();
        other.attachment_generation = 1;
        other.applied_frame_id = 1;
        for (other.buffer.cells) |*cell| {
            cell.* = .{};
            cell.bytes[0] = 'b';
        }
        const area: core.Rect = .{ .w = size.cols, .h = size.rows };
        var before: core.ProfileCounters = .{};
        var started: i96 = 0;
        var checksum: usize = 0;
        var allocated: usize = 0;
        const warm_until = std.Io.Clock.awake.now(self.io).nanoseconds + self.warmup_ns;
        const warm_cycle = if (mode == .sparse) 2 * pane.buffer.cells.len else if (multiple) 2 * size.cols else 20;
        var index: usize = 0;
        while (index < preheat + samples) : (index += 1) {
            if (index == preheat and self.warmup_ns > 0 and (std.Io.Clock.awake.now(self.io).nanoseconds < warm_until or index % warm_cycle != 0)) {
                preheat += 1;
            }

            if (index == preheat) {
                before = core.profiling.snapshot();
                allocated = accounting.allocations;
                started = std.Io.Clock.awake.now(self.io).nanoseconds;
            }
            const step = index -| preheat;
            const stimulus = if (index < preheat) index else step;
            switch (mode) {
                .retained, .selection => {},
                .cursor => pane.cursor.x = @intCast(stimulus % size.cols),
                .focus => renderer.focused = stimulus % 2 == 0,
                .reattach => pane.attachment_generation += 1,
                .two_one_active, .two_all_active => {
                    const first = &pane.buffer.cells[stimulus % size.cols];
                    first.bytes[0] = if (first.bytes[0] == 'a') 'b' else 'a';
                    pane.applied_frame_id += 1;
                    if (mode == .two_all_active) {
                        const second = &other.buffer.cells[stimulus % size.cols];
                        second.bytes[0] = if (second.bytes[0] == 'a') 'b' else 'a';
                        other.applied_frame_id += 1;
                    }
                },
                .font => {
                    renderer.config.font.size = if (stimulus % 2 == 0) 14 else 15;
                    renderer.scale = 0;
                    _ = try renderer.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1], .scale = 1 });
                },
                .sparse => {
                    pane.applied_frame_id += 1;
                    const cell = &pane.buffer.cells[stimulus % pane.buffer.cells.len];
                    cell.bytes[0] = if (cell.bytes[0] == 'a') 'b' else 'a';
                },
                .full => {
                    pane.applied_frame_id += 1;
                    for (pane.buffer.cells) |*cell| {
                        cell.bytes[0] = @intCast('a' + stimulus % 20);
                    }
                },
                .theme => renderer.theme.background[0] = @intCast(stimulus % 200),
                .resize => _ = try renderer.measure(.{ .width = renderer.viewport[0], .height = renderer.viewport[1] + (if (stimulus % 2 == 0) @as(u32, 1) else 0) - (if (stimulus % 2 == 1) @as(u32, 1) else 0), .scale = 1 }),
            }
            renderer.begin();
            const first_area: core.Rect = if (multiple) .{ .w = area.w, .h = area.h / 2 } else area;
            try renderer.drawPane(.{ .pane = &pane, .view = .{ .pane_id = pane.id, .outer = first_area, .content = first_area, .focused = true, .display_index = 1 }, .hide_cursor = mode != .cursor and mode != .focus, .copy = if (mode == .selection) .{ .cursor = .{ .x = @intCast(stimulus % size.cols), .y = @intCast(stimulus % size.rows) }, .anchor = .{ .x = 0, .y = 0 }, .linewise = false, .pointer = true } else null });
            if (multiple) {
                const second_area: core.Rect = .{ .y = first_area.h, .w = area.w, .h = area.h - first_area.h };
                try renderer.drawPane(.{ .pane = &other, .view = .{ .pane_id = other.id, .outer = second_area, .content = second_area, .focused = false, .display_index = 2 }, .hide_cursor = true });
            }
            renderer.seal();
            if (mode == .sparse and index > 0 and renderer.repainted_cells != 1) {
                return error.InvalidSparseWorkload;
            }
            if (multiple and index > 0 and renderer.repainted_cells != @as(usize, if (mode == .two_all_active) 2 else 1)) {
                return error.InvalidSplitWorkload;
            }
            if (mode == .full and renderer.repainted_cells != pane.buffer.cells.len) {
                return error.InvalidFullWorkload;
            }
            checksum +%= renderer.quads.items().len;
            if (self.verify) {
                var quad_digest: [32]u8 = undefined;
                var atlas_digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(renderer.quads.items()), &quad_digest, .{});
                std.crypto.hash.sha2.Sha256.hash(renderer.atlas.?.pixels, &atlas_digest, .{});
                try self.writer.print("{{\"type\":\"frame\",\"mode\":\"{s}\",\"cols\":{d},\"index\":{d},\"quads\":\"{s}\",\"atlas\":\"{s}\"}}\n", .{ @tagName(mode), cols, index, std.fmt.bytesToHex(quad_digest, .lower), std.fmt.bytesToHex(atlas_digest, .lower) });
            }
        }
        const elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - started;
        if (checksum == 0) {
            return error.EmptyTerminalWorkload;
        }
        try self.writer.print("{{\"type\":\"workload\",\"name\":\"terminal/{s}/{d}x{d}\",\"iterations\":{d},\"warmup\":{d},\"elapsed_ns\":{d},\"checksum\":{d},\"live_requested_bytes\":{d},\"retained_length\":{d},\"retained_capacity\":{d},\"last_frame_quads\":{d},\"measured_allocations\":{d},", .{ @tagName(mode), size.cols, size.rows, samples, preheat, elapsed, checksum, accounting.allocated_bytes - accounting.freed_bytes, renderer.retained.entries.items.len, renderer.retained.entries.capacity, renderer.quads.items().len, accounting.allocations - allocated });
        try self.counts(before);
    }

    fn review(self: *Probe, lines: usize) !void {
        var source: std.Io.Writer.Allocating = .init(self.gpa);
        defer source.deinit();
        try source.writer.print("diff --git a/example.zig b/example.zig\n--- a/example.zig\n+++ b/example.zig\n@@ -0,0 +1,{d} @@\n", .{lines});
        for (0..lines) |_| {
            try source.writer.writeAll("+const value = 42;\n");
        }
        const widget = try self.gpa.create(Widget);
        defer self.gpa.destroy(widget);
        widget.* = .{};
        widget.model.revisions[0].load(source.written()) catch |err| {
            if (lines != 10000 or err != error.ReviewLineLimit) {
                return err;
            }
            try self.writer.writeAll("{\"type\":\"capacity\",\"name\":\"review/10000\",\"expected_error\":\"ReviewLineLimit\"}\n");
            return;
        };
        if (widget.model.revisions[0].row_count != lines) {
            return error.InvalidReviewFixture;
        }
        @memset(&widget.roles[0], .plain);
        _ = widget.model.search.setQuery("value");
        var renderer = Renderer.init(self.gpa);
        defer renderer.deinit();
        _ = try renderer.measure(.{ .width = 1200, .height = 900, .scale = 1 });
        var canvas = makeCanvas(&renderer);
        const state = try self.gpa.create(State);
        defer self.gpa.destroy(state);
        state.* = .{};
        defer state.deinit();
        canvas.widgets = state;
        var before: core.ProfileCounters = .{};
        var started: i96 = 0;
        var checksum: usize = 0;
        for (0..warmup + iterations) |index| {
            if (index == warmup) {
                before = core.profiling.snapshot();
                started = std.Io.Clock.awake.now(self.io).nanoseconds;
            }
            renderer.begin();
            state.begin(true);
            try widget.draw(&canvas);
            state.seal();
            state.present(true);
            checksum +%= renderer.quads.items().len;
        }
        if (checksum == 0) {
            return error.EmptyReviewWorkload;
        }
        try self.writer.print("{{\"type\":\"workload\",\"name\":\"review/search/{d}\",\"iterations\":{d},\"warmup\":{d},\"elapsed_ns\":{d},\"checksum\":{d},", .{ lines, iterations, warmup, std.Io.Clock.awake.now(self.io).nanoseconds - started, checksum });
        try self.counts(before);
    }

    fn conversation(self: *Probe, transcript: Transcript) !void {
        const snapshot = try self.gpa.create(core.AgentThreadSnapshot);
        defer self.gpa.destroy(snapshot);
        snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 1, .status = .working };
        const message = "A deterministic reply with **bold text** and `code`.\n";
        var len: usize = 0;
        var word: usize = 0;
        for (0..32) |index| {
            const start = len;
            switch (transcript) {
                .repeated => {
                    @memcpy(snapshot.text_storage[len..][0..message.len], message);
                    len += message.len;
                },
                .distinct => while (len - start < 600) : (word += 1) {
                    len += (try std.fmt.bufPrint(snapshot.text_storage[len..], "word{d}x ", .{word})).len;
                },
            }

            snapshot.item_storage[index] = .{ .identity = index + 1, .turn_identity = index + 1, .role = .assistant, .status = .completed, .text_offset = @intCast(start), .text_len = @intCast(len - start) };
        }

        snapshot.item_count = 32;
        snapshot.text_len = @intCast(len);
        var renderer = Renderer.init(self.gpa);
        defer renderer.deinit();
        _ = try renderer.measure(.{ .width = 1200, .height = 900, .scale = 1 });
        var canvas = makeCanvas(&renderer);
        const state = try self.gpa.create(State);
        defer self.gpa.destroy(state);
        state.* = .{};
        defer state.deinit();
        canvas.widgets = state;
        const flow = try self.gpa.create(ThreadFlow);
        defer self.gpa.destroy(flow);
        flow.* = .{ .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 700 }, .thread = .{ .pane_id = snapshot.pane_id, .agent = null, .composer = "", .transcript = snapshot } };
        var before: core.ProfileCounters = .{};
        var started: i96 = 0;
        var checksum: usize = 0;
        for (0..warmup + iterations) |index| {
            if (index == warmup) {
                before = core.profiling.snapshot();
                started = std.Io.Clock.awake.now(self.io).nanoseconds;
            }
            renderer.begin();
            state.begin(false);
            try flow.resolve(&canvas);
            try flow.draw(&canvas);
            state.seal();
            state.present(true);
            checksum +%= renderer.quads.items().len;
        }
        if (checksum == 0 or flow.len != 32) {
            return error.InvalidConversationWorkload;
        }
        try self.writer.print("{{\"type\":\"workload\",\"name\":\"agent/32-messages/{s}\",\"iterations\":{d},\"warmup\":{d},\"elapsed_ns\":{d},\"checksum\":{d},", .{ @tagName(transcript), iterations, warmup, std.Io.Clock.awake.now(self.io).nanoseconds - started, checksum });
        try self.counts(before);
    }

    fn workspace(self: *Probe, count: usize) !void {
        var accounting = std.testing.FailingAllocator.init(self.gpa, .{});
        const model = try accounting.allocator().create(data.ClientModel);
        defer accounting.allocator().destroy(model);
        model.* = .init(accounting.allocator(), true);
        defer model.deinit();
        const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
        const size: core.TerminalSize = .{ .cols = 80, .rows = 40 };
        try data.workspace_handoff.bootstrap(model, .{ .pane_id = @enumFromInt(1), .location = location, .size = size });
        for (1..count) |index| {
            _ = try data.tab_creation.add(model, .{ .location = .{ .workspace = location.workspace, .tab_id = @enumFromInt(index + 1) }, .position = @intCast(index), .label = "probe", .root_pane_id = @enumFromInt(index + 1) }, size);
        }
        var checksum: usize = 0;
        const before = core.profiling.snapshot();
        const started = std.Io.Clock.awake.now(self.io).nanoseconds;
        for (0..iterations) |_| {
            for (1..count + 1) |index| {
                const pane = model.panes.find(@enumFromInt(index)) orelse return error.MissingWorkspacePane;
                checksum +%= core.raw(pane.id);
            }
        }
        const elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - started;
        try self.writer.print("{{\"type\":\"workload\",\"name\":\"workspace/{d}-tabs\",\"iterations\":{d},\"lookup_requests\":{d},\"elapsed_ns\":{d},\"checksum\":{d},\"live_requested_bytes\":{d},", .{ count, iterations, iterations * count, elapsed, checksum, accounting.allocated_bytes - accounting.freed_bytes });
        try self.counts(before);
    }

    fn counts(self: *Probe, before: core.ProfileCounters) !void {
        const after = core.profiling.snapshot();
        if (comptime core.profiling.enabled) {
            if (after.overflow) {
                return error.ProfileCounterOverflow;
            }
            const draws = after.values[@intFromEnum(core.profiling.Metric.gui_pane_draw)] - before.values[@intFromEnum(core.profiling.Metric.gui_pane_draw)];
            const visits = after.values[@intFromEnum(core.profiling.Metric.gui_cell_visit)] - before.values[@intFromEnum(core.profiling.Metric.gui_cell_visit)];
            const hits = after.values[@intFromEnum(core.profiling.Metric.mesh_hit)] - before.values[@intFromEnum(core.profiling.Metric.mesh_hit)];
            const rebuilt = after.values[@intFromEnum(core.profiling.Metric.mesh_rebuild)] - before.values[@intFromEnum(core.profiling.Metric.mesh_rebuild)];
            if (draws > 0 and hits + rebuilt != visits) {
                return error.InvalidMeshCounters;
            }
        }
        try self.writer.writeAll("\"counts\":{");
        inline for (std.meta.tags(core.profiling.Metric), 0..) |metric, index| {
            try self.writer.print("{s}\"{s}\":{d}", .{ if (index == 0) "" else ",", @tagName(metric), after.values[index] - before.values[index] });
        }
        try self.writer.writeAll("}}\n");
    }

    fn makeCanvas(renderer: *Renderer) Canvas {
        return .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = data.theme_support.default_theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
    }
};
