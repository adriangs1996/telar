//! Reproducible benchmarks for telar's interactive path.
const vtgrid = @import("vtgrid");
const assets = @import("assets");
const keyinput = @import("keyinput");

const pacing = @import("pacing");
const textraster = @import("textraster");
const vtscan = @import("vtscan");
const cellgrid = @import("cellgrid");
const profile_options = @import("profile_options");
const data = @import("model");
const core = @import("telar-core");
const backend = @import("telar-backend");
const client = @import("telar-client");
const std = @import("std");
const DamageContext = @import("DamageContext.zig");
const FrameContext = @import("FrameContext.zig");
const EncodeContext = @import("EncodeContext.zig");
const KeybindContext = @import("KeybindContext.zig");
const BlitContext = @import("BlitContext.zig");
const LayoutContext = @import("LayoutContext.zig");
const KgpIngestContext = @import("KgpIngestContext.zig");
const SharedFrameContext = @import("SharedFrameContext.zig");
const IdleDeliveryContext = @import("IdleDeliveryContext.zig");
const ClientEventContext = @import("ClientEventContext.zig");
const InboxContext = @import("InboxContext.zig");
const IdleDeliveryShape = @import("IdleDeliveryShape.zig");
const Fixture = @import("Fixture.zig");
const Config = @import("Config.zig");
const client_storage = @import("client_storage.zig");
const builtin = @import("builtin");

pub const cols: u16 = 154;
pub const rows: u16 = 37;
pub const cell_count: usize = @as(usize, cols) * rows;
pub const max_samples = 200;
const fragmented_rows = 28;
const fragmented_clusters_per_row = 2;
const fragmented_spans_per_cluster = 4;
const fragmented_spans_per_row = fragmented_clusters_per_row * fragmented_spans_per_cluster;
const fragmented_span_cells = 2;
const fragmented_gap_cells = 2;
pub const fragmented_span_count = fragmented_rows * fragmented_spans_per_row;
const history_input = "\x1b[200~echo one\necho two\x1b[201~\r";

pub const Workload = enum { one_cell, fragmented, full_screen };
const workloads = [_]Workload{ .one_cell, .fragmented, .full_screen };

const usage =
    \\Usage: zig build bench -- [options]
    \\
    \\Options:
    \\  --filter <text>       Run benchmarks whose name contains text
    \\  --samples <count>     Samples per benchmark, default 12
    \\  --sample-ms <ms>      Target duration of each sample, default 40
    \\  --json                Emit JSON Lines for storage and comparison
    \\  --enforce             Fail when a case exceeds its p99 release budget
    \\  --list                Print benchmark names without running them
    \\  --storage             Report client sizes and live pane allocations as JSON Lines
    \\  --help                Print this help
;

const cases = [_]Case{
    .{ .name = "backend.damage.one_cell", .work_per_op = cols, .work_unit = "cells" },
    .{ .name = "backend.damage.fragmented", .work_per_op = fragmented_rows * cols, .work_unit = "cells" },
    .{ .name = "backend.damage.full_screen", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "backend.frame.fragmented", .work_per_op = fragmented_rows * cols, .work_unit = "cells" },
    .{ .name = "backend.history.input_scan", .work_per_op = history_input.len, .work_unit = "bytes" },
    .{ .name = "schema.encode.one_cell", .work_per_op = 1, .work_unit = "cells" },
    .{ .name = "schema.encode.fragmented", .work_per_op = fragmented_span_count * fragmented_span_cells, .work_unit = "cells" },
    .{ .name = "schema.encode.full_screen", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "schema.decode.one_cell", .work_per_op = 1, .work_unit = "cells" },
    .{ .name = "schema.decode.fragmented", .work_per_op = fragmented_span_count * fragmented_span_cells, .work_unit = "cells" },
    .{ .name = "schema.decode.full_screen", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "frontend.outbox.input", .work_per_op = 12, .work_unit = "bytes" },
    .{ .name = "client.keybind.route", .work_per_op = keybind_keys.len, .work_unit = "keys" },
    .{ .name = "frontend.lua.callback", .work_per_op = 1, .work_unit = "callbacks" },
    .{ .name = "frontend.pacer.late_frame", .work_per_op = 1, .work_unit = "frames" },
    .{ .name = "frontend.layout.directional_focus", .work_per_op = 4, .work_unit = "panes" },
    .{
        .name = "backend.kitty.ingest_zlib_rgba_1920x1080",
        .work_per_op = 1920 * 1080,
        .work_unit = "pixels",
        .p99_budget_ns = 100 * std.time.ns_per_ms,
    },
    .{
        .name = "backend.kitty.shared_frame_3840x2160.publish",
        .work_per_op = 3840 * 2160,
        .work_unit = "pixels",
        .p99_budget_ns = 100 * std.time.ns_per_ms,
    },
    .{
        .name = "backend.kitty.shared_frame_3840x2160.ingest",
        .work_per_op = 3840 * 2160,
        .work_unit = "pixels",
        .p99_budget_ns = 100 * std.time.ns_per_ms,
    },
    .{
        .name = "backend.kitty.shared_frame_3840x2160.freeze",
        .work_per_op = 3840 * 2160,
        .work_unit = "pixels",
        .p99_budget_ns = 100 * std.time.ns_per_ms,
    },
    .{
        .name = "frontend.text.rasterize_jetbrains_mono",
        .work_per_op = 51,
        .work_unit = "glyphs",
        .p99_budget_ns = std.time.ns_per_ms,
    },
    .{ .name = "backend.blit.full_screen", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "backend.delivery.flush_idle_2x8", .work_per_op = 1, .work_unit = "flushes" },
    .{ .name = "backend.delivery.flush_idle_1x32", .work_per_op = 1, .work_unit = "flushes" },
    .{ .name = "frontend.client.frame_event", .work_per_op = 1, .work_unit = "frames" },
    .{ .name = "frontend.client.key_event", .work_per_op = 1, .work_unit = "keys" },
    .{ .name = "frontend.client.request_group_query", .work_per_op = 1, .work_unit = "queries" },
    .{ .name = "frontend.client.present_frame", .work_per_op = 1, .work_unit = "frames" },
    .{ .name = "frontend.client.inbox_event", .work_per_op = 1, .work_unit = "events" },
};

/// Two clients on one eight-pane tab, and one client on a crowded tab.
const idle_delivery_shapes = [_]IdleDeliveryShape{
    .{ .clients = 2, .panes = 8, .size = .{ .cols = cols, .rows = rows } },
    .{ .clients = 1, .panes = 32, .size = .{ .cols = cols, .rows = rows } },
};

fn timestamp(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn timed(input: anytype, iterations: usize, comptime run: fn (@TypeOf(input.context), usize) anyerror!u64) !u64 {
    const started = timestamp(input.io);
    const checksum = try run(input.context, iterations);
    const elapsed = timestamp(input.io) - started;
    std.mem.doNotOptimizeAway(checksum);
    return elapsed;
}

fn measure(input: anytype, comptime run: fn (@TypeOf(input.context), usize) anyerror!u64) !Measurement {
    var iterations: usize = 1;
    while (true) {
        const elapsed = try timed(input, iterations, run);
        if (elapsed >= input.config.sample_ns / 4 or iterations >= 1 << 30) {
            if (elapsed != 0 and elapsed < input.config.sample_ns) {
                const scaled = @as(u128, iterations) * input.config.sample_ns / elapsed;
                iterations = @max(iterations, @as(usize, @intCast(@min(scaled, 1 << 30))));
            }
            break;
        }
        iterations *= 4;
    }

    _ = try timed(input, iterations, run);

    var samples: [max_samples]u64 = undefined;
    for (samples[0..input.config.samples]) |*sample| {
        const elapsed = try timed(input, iterations, run);
        sample.* = elapsed / iterations;
    }
    std.sort.heap(u64, samples[0..input.config.samples], {}, std.sort.asc(u64));

    const p95_index = (input.config.samples * 95 + 99) / 100 - 1;
    const p99_index = (input.config.samples * 99 + 99) / 100 - 1;
    return .{
        .iterations = iterations,
        .minimum_ns = samples[0],
        .median_ns = samples[input.config.samples / 2],
        .p95_ns = samples[p95_index],
        .p99_ns = samples[p99_index],
    };
}

pub fn frame(frame_id: u64, spans: []const core.Span) core.Frame {
    return .{
        .pane_id = @enumFromInt(1),
        .frame_id = frame_id,
        .base_frame_id = 1,
        .cols = cols,
        .rows = rows,
        .scroll = .{ .total_rows = rows, .offset = 0 },
        .spans = spans,
    };
}

pub fn fillEditor(cells: []cellgrid.Cell, variant: u8) void {
    for (cells, 0..) |*cell, index| {
        const x = index % cols;
        const y = index / cols;
        cell.* = .{};
        cell.bytes[0] = 'a' + @as(u8, @intCast((x + y + variant) % 26));
        if (x < 5) {
            cell.style.fg = .indexed(8);
        } else if ((x / 11 + y) % 5 == 0) {
            cell.style.fg = .indexed(12);
        } else if ((x / 17 + y) % 7 == 0) {
            cell.style.fg = .indexed(10);
            cell.style.flags.bold = true;
        }
    }
}

pub fn fillFragmentedSpans(spans: []core.Span, cells: []const cellgrid.Cell) void {
    var span_index: usize = 0;
    for (0..fragmented_rows) |y| {
        for ([_]usize{ 12, 91 }) |cluster_start| {
            for (0..fragmented_spans_per_cluster) |run| {
                const x = cluster_start + run * (fragmented_span_cells + fragmented_gap_cells);
                const start = y * cols + x;
                spans[span_index] = .{
                    .start = @intCast(start),
                    .cells = cells[start..][0..fragmented_span_cells],
                };
                span_index += 1;
            }
        }
    }
}

fn runDamage(context: *DamageContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.current[context.changed_index].bytes[0] = if (iteration & 1 == 0) '0' else '1';
        const diff = vtgrid.collectSpans(
            core.Span,
            .off,
            .{
                .current = context.current,
                .acknowledged = context.acknowledged,
                .cols = cols,
                .damaged_rows = context.damaged_rows,
                .span_header_size = core.span_header_size,
            },
            context.spans,
        );
        checksum +%= diff.scanned_cells + diff.span_count;
    }
    return checksum;
}

fn runIdleDelivery(context: *IdleDeliveryContext, iterations: usize) !u64 {
    for (0..iterations) |_| {
        try context.idle.flush();
    }

    if (!context.idle.quiet()) {
        return error.IdleDeliveryStartedWrite;
    }

    return iterations;
}

fn runFrame(context: *FrameContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.damage.current[context.damage.changed_index].bytes[0] =
            if (iteration & 1 == 0) '0' else '1';
        const payload = try context.encode();
        checksum +%= payload.len + payload[payload.len - 1];
    }
    return checksum;
}

fn runHistoryInput(context: *HistoryInputContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        context.scanner.reset();
        const event = context.scanner.feed(history_input);
        checksum +%= @intFromBool(event.submitted);
        checksum +%= @as(u64, @intFromBool(event.cancelled)) << 1;
    }
    return checksum;
}

fn runEncode(context: *EncodeContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        const spans = context.fixture.spans(context.workload, iteration & 1);
        const payload = try core.encodePaneFrame(context.fixture.encode_buffer, frame(2, spans));
        checksum +%= payload.len;
        checksum +%= payload[payload.len - 1];
    }
    return checksum;
}

fn runDecode(context: *DecodeContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        const message = try core.decodeServer(context.payloads[iteration & 1]);
        const decoded = message.pane_frame;
        checksum +%= decoded.encoded_spans.len + decoded.span_count + decoded.frame_id;
    }
    return checksum;
}

fn runOutboxInput(context: *OutboxContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        try context.outbox.pushInput(@enumFromInt(1), "hello world\n");
        checksum +%= context.outbox.len;
        checksum +%= (try context.outbox.beginSend(&context.buffer)).?.len;
        context.outbox.popSent();
    }
    return checksum;
}

pub const KeybindAction = enum(u8) { detach, palette };
pub const KeybindBinding = keyinput.GenericBinding(KeybindAction, 4);
pub const KeybindRouter = keyinput.GenericRouter(KeybindAction, .{
    .max_bindings = 16,
    .max_keys = 4,
    .input_capacity = 64,
    .held_capacity = 32,
    .max_physical_leases = data.keybind.max_physical_leases,
    .escape_timeout_ns = data.keybind.default_escape_timeout_ns,
    .sequence_timeout_ns = data.keybind.default_sequence_timeout_ns,
}, struct {});

/// What one iteration routes: typing, then the detach chord.
pub const keybind_keys = "cargo test";

fn runKeybind(context: *KeybindContext, iterations: usize) !u64 {
    for (0..iterations) |iteration| {
        for (context.keys) |key| {
            const decision = context.router.routeEvent(.{ .key = key, .raw = "", .now_ns = iteration }, .{});
            switch (decision) {
                .forward => |forward| context.checksum +%= @intFromEnum(forward.key.code),
                .action => |request| {
                    context.checksum +%= @intFromEnum(request.value) + 1;
                    context.router.actionCompleted(request, null);
                },
                .pending => {},
                .replay, .discard => return error.UnexpectedBenchmarkDecision,
            }
        }
    }
    return context.checksum;
}

fn runLuaCallback(context: *LuaCallbackContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const batch = try context.generation.invokeCallback(.{
            .reference = context.reference,
            .context = .{
                .sidebar_visible = true,
                .tab_count = 8,
                .active_tab_index = 3,
                .pane_count = 4,
                .focused_pane_id = 7,
            },
        }, &context.diagnostic);
        checksum +%= batch.len;
    }
    return checksum;
}

fn runPacer(context: *PacerContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        if (context.pacer.waitUntil(context.now_ns)) |deadline_ns| {
            context.now_ns = deadline_ns + 2 * std.time.ns_per_ms;
            context.pacer.record(.{ .now = context.now_ns, .scheduled_deadline = deadline_ns, .absorbed = 1 });
        } else {
            context.pacer.record(.{ .now = context.now_ns, .scheduled_deadline = null, .absorbed = 1 });
        }
        checksum +%= context.pacer.anchor_ns.?;
    }
    return checksum;
}

fn runLayoutFocus(context: *LayoutContext, iterations: usize) !u64 {
    const directions = [_]data.layout.Direction{ .right, .down, .left, .up };
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        if (context.layout.focusDirection(directions[iteration & 3], context.area)) |pane_id| {
            checksum +%= core.raw(pane_id);
        }
    }
    return checksum;
}

fn runKgpIngest(context: *KgpIngestContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        context.stream.nextSlice(context.command);
        const image = context.terminal.screens.active.kitty_images.imageById(7) orelse
            return error.KgpImageMissing;
        checksum +%= image.generation + image.data.len();
    }
    return checksum;
}

fn runSharedFramePublish(context: *SharedFrameContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        try context.publish();
        context.unpublish();
        checksum +%= context.envelope_len;
    }
    return checksum;
}

fn runSharedFrameIngest(context: *SharedFrameContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        try context.publish();
        checksum +%= try context.ingest();
    }
    return checksum;
}

fn runSharedFrameFreeze(context: *SharedFrameContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| checksum +%= try context.freeze();
    return checksum;
}

fn runTextRaster(context: *TextRasterContext, iterations: usize) !u64 {
    const surface: textraster.Surface = .{
        .pixels = context.pixels,
        .width = TextRasterContext.width,
        .height = TextRasterContext.height,
    };
    const color: textraster.Color = .{
        .red = 220,
        .green = 230,
        .blue = 240,
    };
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= try context.rasterizer.drawText(.{ .surface = surface, .origin = .{ .x = 20, .y = 18 }, .text = "Build complete", .color = color, .max_width = 420 });
        checksum +%= try context.rasterizer.drawText(.{ .surface = surface, .origin = .{ .x = 20, .y = 38 }, .text = "Open the rendered result", .color = color, .max_width = 420 });
        checksum +%= try context.rasterizer.drawText(.{ .surface = surface, .origin = .{ .x = 20, .y = 58 }, .text = "click to open", .color = color, .max_width = 420 });
    }
    return checksum +% context.pixels[context.pixels.len / 2];
}

fn runBlit(context: *BlitContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= context.blitAll();
    }

    return checksum;
}

fn execute(result_writer: ResultWriter, resources: ExecutionResources, fixture: *Fixture) !void {
    const io = resources.io;
    const gpa = resources.gpa;
    const config = result_writer.config;
    var case_index: usize = 0;

    inline for (workloads) |workload| {
        const case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            var context = try DamageContext.init(gpa, fixture, workload);
            defer context.deinit();
            try result_writer.write(case, try measure(.{ .io = io, .config = config, .context = &context }, runDamage));
        }
    }

    var frame_case = cases[case_index];
    case_index += 1;
    if (config.includes(frame_case.name)) {
        var context = try FrameContext.init(gpa, fixture);
        defer context.deinit();
        frame_case.payload_bytes_per_op = (try context.encode()).len;
        try result_writer.write(frame_case, try measure(.{ .io = io, .config = config, .context = &context }, runFrame));
    }

    const history_input_case = cases[case_index];
    case_index += 1;
    if (config.includes(history_input_case.name)) {
        var context: HistoryInputContext = .{};
        try result_writer.write(
            history_input_case,
            try measure(.{ .io = io, .config = config, .context = &context }, runHistoryInput),
        );
    }

    inline for (workloads) |workload| {
        var case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            const payloads = fixture.payloads(workload);
            case.payload_bytes_per_op = (payloads[0].len + payloads[1].len) / 2;
            var context: EncodeContext = .{ .fixture = fixture, .workload = workload };
            try result_writer.write(case, try measure(.{ .io = io, .config = config, .context = &context }, runEncode));
        }
    }

    inline for (workloads) |workload| {
        var case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            const payloads = fixture.payloads(workload);
            case.payload_bytes_per_op = (payloads[0].len + payloads[1].len) / 2;
            var context: DecodeContext = .{
                .payloads = payloads,
            };
            try result_writer.write(case, try measure(.{ .io = io, .config = config, .context = &context }, runDecode));
        }
    }

    const outbox_case = cases[case_index];
    case_index += 1;
    if (config.includes(outbox_case.name)) {
        var context = try OutboxContext.init(gpa);
        defer context.deinit(gpa);
        try result_writer.write(outbox_case, try measure(.{ .io = io, .config = config, .context = &context }, runOutboxInput));
    }

    const keybind_case = cases[case_index];
    case_index += 1;
    if (config.includes(keybind_case.name)) {
        var context = try KeybindContext.init();
        try result_writer.write(keybind_case, try measure(.{ .io = io, .config = config, .context = &context }, runKeybind));
    }

    const lua_callback_case = cases[case_index];
    case_index += 1;
    if (config.includes(lua_callback_case.name)) {
        var context = try LuaCallbackContext.init(gpa, io);
        defer context.deinit();
        try result_writer.write(
            lua_callback_case,
            try measure(.{ .io = io, .config = config, .context = &context }, runLuaCallback),
        );
    }

    const pacer_case = cases[case_index];
    case_index += 1;
    if (config.includes(pacer_case.name)) {
        var context: PacerContext = .{};
        try result_writer.write(pacer_case, try measure(.{ .io = io, .config = config, .context = &context }, runPacer));
    }

    const layout_case = cases[case_index];
    case_index += 1;
    if (config.includes(layout_case.name)) {
        var context = try LayoutContext.init();
        try result_writer.write(layout_case, try measure(.{ .io = io, .config = config, .context = &context }, runLayoutFocus));
    }

    var kgp_case = cases[case_index];
    case_index += 1;
    if (config.includes(kgp_case.name)) {
        var context = try KgpIngestContext.init(io, gpa);
        defer context.deinit();
        kgp_case.payload_bytes_per_op = context.command.len;
        try result_writer.write(
            kgp_case,
            try measure(.{ .io = io, .config = config, .context = &context }, runKgpIngest),
        );
    }

    const shared_publish_case = cases[case_index];
    const shared_ingest_case = cases[case_index + 1];
    const shared_freeze_case = cases[case_index + 2];
    case_index += 3;
    if (config.includes(shared_publish_case.name) or config.includes(shared_ingest_case.name) or
        config.includes(shared_freeze_case.name))
    {
        var context = try SharedFrameContext.init(io, gpa);
        defer context.deinit();
        if (config.includes(shared_publish_case.name)) {
            try result_writer.write(
                shared_publish_case,
                try measure(.{ .io = io, .config = config, .context = &context }, runSharedFramePublish),
            );
        }
        if (config.includes(shared_ingest_case.name)) {
            try result_writer.write(
                shared_ingest_case,
                try measure(.{ .io = io, .config = config, .context = &context }, runSharedFrameIngest),
            );
        }
        if (config.includes(shared_freeze_case.name)) {
            try result_writer.write(
                shared_freeze_case,
                try measure(.{ .io = io, .config = config, .context = &context }, runSharedFrameFreeze),
            );
        }
    }

    const text_raster_case = cases[case_index];
    case_index += 1;
    if (config.includes(text_raster_case.name)) {
        var context = try TextRasterContext.init(gpa);
        defer context.deinit();
        try result_writer.write(
            text_raster_case,
            try measure(.{ .io = io, .config = config, .context = &context }, runTextRaster),
        );
    }

    const blit_case = cases[case_index];
    case_index += 1;
    if (config.includes(blit_case.name)) {
        var context = try BlitContext.init(gpa, io);
        defer context.deinit();
        try result_writer.write(
            blit_case,
            try measure(.{ .io = io, .config = config, .context = &context }, runBlit),
        );
    }

    for (idle_delivery_shapes) |shape| {
        const case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            var context: IdleDeliveryContext = undefined;
            try context.init(io, gpa, resources.environ, shape);
            defer context.deinit();
            try result_writer.write(case, try measure(.{ .io = io, .config = config, .context = &context }, runIdleDelivery));
        }
    }
    const client_frame_case = cases[case_index];
    const client_key_case = cases[case_index + 1];
    const client_request_case = cases[case_index + 2];
    const client_present_case = cases[case_index + 3];
    case_index += 4;
    if (config.includes(client_frame_case.name) or config.includes(client_key_case.name) or config.includes(client_request_case.name) or config.includes(client_present_case.name)) {
        var context: ClientEventContext = undefined;
        try context.init(io, gpa);
        defer context.deinit();
        if (config.includes(client_frame_case.name)) {
            try result_writer.write(client_frame_case, try measure(.{ .io = io, .config = config, .context = &context }, runClientFrame));
        }

        if (config.includes(client_key_case.name)) {
            try result_writer.write(client_key_case, try measure(.{ .io = io, .config = config, .context = &context }, runClientKey));
        }

        if (config.includes(client_request_case.name)) {
            try context.holdTabSnapshot();
            defer context.releaseTabSnapshot();

            try result_writer.write(client_request_case, try measure(.{ .io = io, .config = config, .context = &context }, runClientRequestGroup));
        }

        if (config.includes(client_present_case.name)) {
            try result_writer.write(client_present_case, try measure(.{ .io = io, .config = config, .context = &context }, runClientPresent));
        }
    }

    const inbox_case = cases[case_index];
    case_index += 1;
    if (config.includes(inbox_case.name)) {
        var context = InboxContext.init(io);
        defer context.deinit();
        try result_writer.write(inbox_case, try measure(.{ .io = io, .config = config, .context = &context }, runInboxEvent));
    }

    std.debug.assert(case_index == cases.len);
}

fn runInboxEvent(context: *InboxContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= try context.roundTrip();
    }

    return checksum;
}

fn runClientFrame(context: *ClientEventContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        checksum +%= try context.frameEvent(iteration);
    }

    return checksum +% context.started_jobs;
}

fn runClientRequestGroup(context: *ClientEventContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= @intFromBool(context.requestGroupQuery());
        std.mem.doNotOptimizeAway(context.app);
    }

    return checksum;
}

fn runClientPresent(context: *ClientEventContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= try context.presentFrame();
    }

    return checksum;
}

fn runClientKey(context: *ClientEventContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= try context.keyEvent();
    }

    return checksum +% context.started_jobs;
}

pub fn main(init: std.process.Init) !void {
    defer {
        if (comptime core.profiling.active) {
            if (init.minimal.environ.getPosix("TELAR_PROFILE_DIR")) |directory| {
                profile_store.dump(init.io, directory) catch {};
            }
        }
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = Config.parse(args) catch |err| switch (err) {
        error.HelpRequested => {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return;
        },
        else => {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return err;
        },
    };

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    if (config.storage) {
        try client_storage.report(writer, init.gpa);
        try writer.flush();
        return;
    }

    if (config.list) {
        for (cases) |case| {
            if (config.includes(case.name)) {
                try writer.print("{s}\n", .{case.name});
            }
        }
        try writer.flush();
        return;
    }

    if (config.json) {
        try writer.print(
            "{{\"type\":\"metadata\",\"zig\":\"{s}\",\"mode\":\"{s}\"," ++
                "\"arch\":\"{s}\",\"cpu\":\"{s}\",\"os\":\"{s}\",\"cols\":{d},\"rows\":{d}," ++
                "\"samples\":{d},\"sample_target_ns\":{d}}}\n",
            .{
                builtin.zig_version_string,
                @tagName(builtin.mode),
                @tagName(builtin.cpu.arch),
                builtin.cpu.model.name,
                @tagName(builtin.os.tag),
                cols,
                rows,
                config.samples,
                config.sample_ns,
            },
        );
    } else {
        try writer.print(
            "telar benchmarks, Zig {s}, {s}, {s}-{s}, {d}x{d}\n" ++
                "{d} samples, {d} ms target per sample\n\n",
            .{
                builtin.zig_version_string,
                @tagName(builtin.mode),
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
                cols,
                rows,
                config.samples,
                config.sample_ns / std.time.ns_per_ms,
            },
        );
    }
    try writer.flush();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var fixture = try Fixture.init(gpa.allocator());
    defer fixture.deinit();

    try execute(.{ .writer = writer, .config = config }, .{ .io = init.io, .gpa = gpa.allocator(), .environ = init.minimal.environ }, &fixture);
    try writer.flush();
}

pub const telar_profile_counts = profile_options.profile_counts;
pub const telar_profile_timing = profile_options.profile_timing;
pub var profile_store: if (core.profiling.active) core.ProfileStore else void = if (core.profiling.active) .{} else {};

const ResultWriter = struct {
    writer: *std.Io.Writer,
    config: Config,

    pub fn write(self: ResultWriter, case: Case, result: Measurement) !void {
        const rate = if (result.median_ns == 0)
            0
        else
            @as(u128, std.time.ns_per_s) * case.work_per_op / result.median_ns;
        if (self.config.json) {
            try self.writer.print(
                "{{\"type\":\"benchmark\",\"name\":\"{s}\",\"iterations\":{d}," ++
                    "\"samples\":{d},\"median_ns_per_op\":{d},\"min_ns_per_op\":{d}," ++
                    "\"p95_ns_per_op\":{d},\"p99_ns_per_op\":{d}," ++
                    "\"work_per_op\":{d},\"work_unit\":\"{s}\"," ++
                    "\"work_per_second\":{d},\"payload_bytes_per_op\":{d}," ++
                    "\"p99_budget_ns\":{d}}}\n",
                .{
                    case.name,
                    result.iterations,
                    self.config.samples,
                    result.median_ns,
                    result.minimum_ns,
                    result.p95_ns,
                    result.p99_ns,
                    case.work_per_op,
                    case.work_unit,
                    rate,
                    case.payload_bytes_per_op,
                    case.p99_budget_ns,
                },
            );
        } else {
            try self.writer.print("{s}\n  median {d} ns/op, p95 {d} ns/op, p99 {d} ns/op, min {d} ns/op, {d} {s}/s", .{
                case.name,
                result.median_ns,
                result.p95_ns,
                result.p99_ns,
                result.minimum_ns,
                rate,
                case.work_unit,
            });
            if (case.payload_bytes_per_op != 0) {
                try self.writer.print(", payload {d} B/op", .{case.payload_bytes_per_op});
            }
            try self.writer.writeByte('\n');
        }
        if (self.config.enforce and result.p99_ns > case.p99_budget_ns) {
            return error.PerformanceBudgetExceeded;
        }
    }
};

const LuaCallbackContext = struct {
    generation: *client.Generation,
    reference: data.InputCallbackRef,
    diagnostic: data.Diagnostic = .{},

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !LuaCallbackContext {
        var diagnostic: data.Diagnostic = .{};
        const generation = try client.Generation.loadSource(.{ .gpa = gpa, .io = io, .diagnostic = &diagnostic }, .{
            .source = "local t=require('telar'); return { api_version=2, client={ keybindings={ t.bind_global({'escape'}, function(ctx) return t.action.toggle_sidebar() end) } } }",
            .source_name = "@benchmark.lua",
            .number = 1,
        });
        return .{
            .generation = generation,
            .reference = generation.snapshot.bindings[0].action.lua_callback,
        };
    }

    pub fn deinit(self: *LuaCallbackContext) void {
        self.generation.deinit();
    }
};

const DecodeContext = struct {
    payloads: [2][]const u8,
};

const HistoryInputContext = struct {
    scanner: vtscan.InputScanner = .{},
};

const Case = struct {
    name: []const u8,
    work_per_op: u64,
    work_unit: []const u8,
    payload_bytes_per_op: u64 = 0,
    p99_budget_ns: u64 = std.time.ns_per_ms,
};

const PacerContext = struct {
    pacer: pacing.Pacer = .{},
    now_ns: u64 = 0,
};

const Measurement = struct {
    iterations: usize,
    median_ns: u64,
    minimum_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
};

const ExecutionResources = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
};

const OutboxContext = struct {
    outbox: *data.Outbox,
    buffer: [4096]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) !OutboxContext {
        const outbox = try gpa.create(data.Outbox);
        errdefer gpa.destroy(outbox);
        outbox.* = try .init(gpa);
        return .{ .outbox = outbox };
    }

    pub fn deinit(self: *OutboxContext, gpa: std.mem.Allocator) void {
        self.outbox.deinit(gpa);
        gpa.destroy(self.outbox);
    }
};

const TextRasterContext = struct {
    pub const width = 480;
    pub const height = 80;

    gpa: std.mem.Allocator,
    rasterizer: textraster.Rasterizer,
    pixels: []u8,

    pub fn init(gpa: std.mem.Allocator) !TextRasterContext {
        var rasterizer = try textraster.Rasterizer.initFont(assets.jetbrains_mono);
        errdefer rasterizer.deinit();
        try rasterizer.setPixelHeight(15);
        const pixels = try gpa.alloc(u8, width * height * 4);
        @memset(pixels, 32);
        return .{ .gpa = gpa, .rasterizer = rasterizer, .pixels = pixels };
    }

    pub fn deinit(self: *TextRasterContext) void {
        self.gpa.free(self.pixels);
        self.rasterizer.deinit();
    }
};
