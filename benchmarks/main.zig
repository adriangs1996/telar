//! Reproducible benchmarks for telar's interactive path.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const vt = @import("ghostty-vt");

const Io = std.Io;
const schema = core.schema;

const cols: u16 = 154;
const rows: u16 = 37;
const cell_count: usize = @as(usize, cols) * rows;
const max_samples = 200;
const fragmented_rows = 28;
const fragmented_clusters_per_row = 2;
const fragmented_spans_per_cluster = 4;
const fragmented_spans_per_row = fragmented_clusters_per_row * fragmented_spans_per_cluster;
const fragmented_span_cells = 2;
const fragmented_gap_cells = 2;
const fragmented_span_count = fragmented_rows * fragmented_spans_per_row;
const history_input = "\x1b[200~echo one\necho two\x1b[201~\r";
const client_ui_tab_counts = [_]usize{ 1, 8, 64 };

const Workload = enum { one_cell, fragmented, full_screen };
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
    \\  --help                Print this help
;

const Config = struct {
    filter: ?[]const u8 = null,
    samples: usize = 12,
    sample_ns: u64 = 40 * std.time.ns_per_ms,
    json: bool = false,
    list: bool = false,
    enforce: bool = false,

    fn parse(args: []const []const u8) !Config {
        var config: Config = .{};
        var index: usize = 1;
        while (index < args.len) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--filter")) {
                index += 1;
                if (index == args.len) {
                    return error.MissingFilter;
                }
                config.filter = args[index];
            } else if (std.mem.eql(u8, arg, "--samples")) {
                index += 1;
                if (index == args.len) {
                    return error.MissingSampleCount;
                }
                config.samples = try std.fmt.parseUnsigned(usize, args[index], 10);
                if (config.samples == 0 or config.samples > max_samples) {
                    return error.InvalidSampleCount;
                }
            } else if (std.mem.eql(u8, arg, "--sample-ms")) {
                index += 1;
                if (index == args.len) {
                    return error.MissingSampleDuration;
                }
                const milliseconds = try std.fmt.parseUnsigned(u64, args[index], 10);
                if (milliseconds == 0 or milliseconds > 5000) {
                    return error.InvalidSampleDuration;
                }
                config.sample_ns = milliseconds * std.time.ns_per_ms;
            } else if (std.mem.eql(u8, arg, "--json")) {
                config.json = true;
            } else if (std.mem.eql(u8, arg, "--list")) {
                config.list = true;
            } else if (std.mem.eql(u8, arg, "--enforce")) {
                config.enforce = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return error.HelpRequested;
            } else {
                return error.UnknownOption;
            }
            index += 1;
        }
        return config;
    }

    fn includes(config: Config, name: []const u8) bool {
        return config.filter == null or std.mem.find(u8, name, config.filter.?) != null;
    }
};

const Case = struct {
    name: []const u8,
    work_per_op: u64,
    work_unit: []const u8,
    payload_bytes_per_op: u64 = 0,
    p99_budget_ns: u64 = std.time.ns_per_ms,
};

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
    .{ .name = "frontend.pipeline.one_cell", .work_per_op = 1, .work_unit = "cells" },
    .{ .name = "frontend.pipeline.fragmented", .work_per_op = fragmented_span_count * fragmented_span_cells, .work_unit = "cells" },
    .{ .name = "frontend.pipeline.full_screen", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "frontend.outbox.input", .work_per_op = 12, .work_unit = "bytes" },
    .{ .name = "frontend.keybind.route", .work_per_op = 12, .work_unit = "keys" },
    .{ .name = "frontend.lua.callback", .work_per_op = 1, .work_unit = "callbacks" },
    .{ .name = "frontend.pacer.late_frame", .work_per_op = 1, .work_unit = "frames" },
    .{ .name = "frontend.flush.cursor_only", .work_per_op = 1, .work_unit = "frames" },
    .{ .name = "frontend.client_ui.chrome.tabs_1", .work_per_op = 2 * cols + sidebar_width * (rows - 2), .work_unit = "cells" },
    .{ .name = "frontend.client_ui.chrome.tabs_8", .work_per_op = 2 * cols + sidebar_width * (rows - 2), .work_unit = "cells" },
    .{ .name = "frontend.client_ui.chrome.tabs_64", .work_per_op = 2 * cols + sidebar_width * (rows - 2), .work_unit = "cells" },
    .{ .name = "frontend.layout.directional_focus", .work_per_op = 4, .work_unit = "panes" },
    .{ .name = "frontend.multiplexer.compose_four", .work_per_op = cell_count, .work_unit = "cells" },
    .{ .name = "frontend.multiplexer.patch_one_cell", .work_per_op = 1, .work_unit = "cells" },
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
    .{ .name = "frontend.kitty.transmit_rgba_64x64", .work_per_op = 64 * 64, .work_unit = "pixels" },
    .{ .name = "frontend.kitty.idle", .work_per_op = 1, .work_unit = "frames" },
    .{
        .name = "frontend.kitty.transmit_rgba_480x360",
        .work_per_op = 480 * 360,
        .work_unit = "pixels",
        .p99_budget_ns = 5 * std.time.ns_per_ms,
    },
    .{
        .name = "frontend.kitty.transmit_rgba_480x360_zlib",
        .work_per_op = 480 * 360,
        .work_unit = "pixels",
        .p99_budget_ns = 10 * std.time.ns_per_ms,
    },
    .{
        .name = "frontend.text.rasterize_jetbrains_mono",
        .work_per_op = 51,
        .work_unit = "glyphs",
        .p99_budget_ns = std.time.ns_per_ms,
    },
};

const Measurement = struct {
    iterations: usize,
    median_ns: u64,
    minimum_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
};

fn timestamp(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

fn timed(io: Io, context: anytype, iterations: usize, comptime run: fn (@TypeOf(context), usize) anyerror!u64) !u64 {
    const started = timestamp(io);
    const checksum = try run(context, iterations);
    const elapsed = timestamp(io) - started;
    std.mem.doNotOptimizeAway(checksum);
    return elapsed;
}

fn measure(io: Io, config: Config, context: anytype, comptime run: fn (@TypeOf(context), usize) anyerror!u64) !Measurement {
    var iterations: usize = 1;
    while (true) {
        const elapsed = try timed(io, context, iterations, run);
        if (elapsed >= config.sample_ns / 4 or iterations >= 1 << 30) {
            if (elapsed != 0 and elapsed < config.sample_ns) {
                const scaled = @as(u128, iterations) * config.sample_ns / elapsed;
                iterations = @max(iterations, @as(usize, @intCast(@min(scaled, 1 << 30))));
            }
            break;
        }
        iterations *= 4;
    }

    _ = try timed(io, context, iterations, run);

    var samples: [max_samples]u64 = undefined;
    for (samples[0..config.samples]) |*sample| {
        const elapsed = try timed(io, context, iterations, run);
        sample.* = elapsed / iterations;
    }
    std.sort.heap(u64, samples[0..config.samples], {}, std.sort.asc(u64));

    const p95_index = (config.samples * 95 + 99) / 100 - 1;
    const p99_index = (config.samples * 99 + 99) / 100 - 1;
    return .{
        .iterations = iterations,
        .minimum_ns = samples[0],
        .median_ns = samples[config.samples / 2],
        .p95_ns = samples[p95_index],
        .p99_ns = samples[p99_index],
    };
}

fn writeResult(writer: *Io.Writer, config: Config, case: Case, result: Measurement) !void {
    const rate = if (result.median_ns == 0)
        0
    else
        @as(u128, std.time.ns_per_s) * case.work_per_op / result.median_ns;
    if (config.json) {
        try writer.print(
            "{{\"type\":\"benchmark\",\"name\":\"{s}\",\"iterations\":{d}," ++
                "\"samples\":{d},\"median_ns_per_op\":{d},\"min_ns_per_op\":{d}," ++
                "\"p95_ns_per_op\":{d},\"p99_ns_per_op\":{d}," ++
                "\"work_per_op\":{d},\"work_unit\":\"{s}\"," ++
                "\"work_per_second\":{d},\"payload_bytes_per_op\":{d}," ++
                "\"p99_budget_ns\":{d}}}\n",
            .{
                case.name,
                result.iterations,
                config.samples,
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
        try writer.print("{s}\n  median {d} ns/op, p95 {d} ns/op, p99 {d} ns/op, min {d} ns/op, {d} {s}/s", .{
            case.name,
            result.median_ns,
            result.p95_ns,
            result.p99_ns,
            result.minimum_ns,
            rate,
            case.work_unit,
        });
        if (case.payload_bytes_per_op != 0) {
            try writer.print(", payload {d} B/op", .{case.payload_bytes_per_op});
        }
        try writer.writeByte('\n');
    }
    if (config.enforce and result.p99_ns > case.p99_budget_ns) {
        return error.PerformanceBudgetExceeded;
    }
}

const Fixture = struct {
    gpa: std.mem.Allocator,
    cells_a: []core.ui.Cell,
    cells_b: []core.ui.Cell,
    encode_buffer: []u8,
    terminal_output: []u8,
    sparse_storage_a: []u8,
    sparse_storage_b: []u8,
    fragmented_storage_a: []u8,
    fragmented_storage_b: []u8,
    full_storage_a: []u8,
    full_storage_b: []u8,
    sparse_spans: [2][1]schema.frame.Span,
    fragmented_spans: [2][]schema.frame.Span,
    full_spans: [2][1]schema.frame.Span,
    sparse_payloads: [2][]const u8,
    fragmented_payloads: [2][]const u8,
    full_payloads: [2][]const u8,

    fn init(gpa: std.mem.Allocator) !Fixture {
        const cells_a = try gpa.alloc(core.ui.Cell, cell_count);
        errdefer gpa.free(cells_a);
        const cells_b = try gpa.alloc(core.ui.Cell, cell_count);
        errdefer gpa.free(cells_b);
        fillEditor(cells_a, 0);
        fillEditor(cells_b, 1);

        const encode_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(encode_buffer);
        const terminal_output = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(terminal_output);
        const sparse_storage_a = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(sparse_storage_a);
        const sparse_storage_b = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(sparse_storage_b);
        const fragmented_storage_a = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(fragmented_storage_a);
        const fragmented_storage_b = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(fragmented_storage_b);
        const full_storage_a = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(full_storage_a);
        const full_storage_b = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(full_storage_b);

        const middle: u32 = @intCast(cell_count / 2);
        const sparse_spans = [2][1]schema.frame.Span{
            .{.{ .start = middle, .cells = cells_a[middle..][0..1] }},
            .{.{ .start = middle, .cells = cells_b[middle..][0..1] }},
        };
        const fragmented_a = try gpa.alloc(schema.frame.Span, fragmented_span_count);
        errdefer gpa.free(fragmented_a);
        const fragmented_b = try gpa.alloc(schema.frame.Span, fragmented_span_count);
        errdefer gpa.free(fragmented_b);
        fillFragmentedSpans(fragmented_a, cells_a);
        fillFragmentedSpans(fragmented_b, cells_b);
        const full_spans = [2][1]schema.frame.Span{
            .{.{ .start = 0, .cells = cells_a }},
            .{.{ .start = 0, .cells = cells_b }},
        };

        const sparse_payload_a = try schema.encodePaneFrame(sparse_storage_a, frame(2, &sparse_spans[0]));
        const sparse_payload_b = try schema.encodePaneFrame(sparse_storage_b, frame(3, &sparse_spans[1]));
        const fragmented_payload_a = try schema.encodePaneFrame(fragmented_storage_a, frame(2, fragmented_a));
        const fragmented_payload_b = try schema.encodePaneFrame(fragmented_storage_b, frame(3, fragmented_b));
        const full_payload_a = try schema.encodePaneFrame(full_storage_a, frame(2, &full_spans[0]));
        const full_payload_b = try schema.encodePaneFrame(full_storage_b, frame(3, &full_spans[1]));

        return .{
            .gpa = gpa,
            .cells_a = cells_a,
            .cells_b = cells_b,
            .encode_buffer = encode_buffer,
            .terminal_output = terminal_output,
            .sparse_storage_a = sparse_storage_a,
            .sparse_storage_b = sparse_storage_b,
            .fragmented_storage_a = fragmented_storage_a,
            .fragmented_storage_b = fragmented_storage_b,
            .full_storage_a = full_storage_a,
            .full_storage_b = full_storage_b,
            .sparse_spans = sparse_spans,
            .fragmented_spans = .{ fragmented_a, fragmented_b },
            .full_spans = full_spans,
            .sparse_payloads = .{ sparse_payload_a, sparse_payload_b },
            .fragmented_payloads = .{ fragmented_payload_a, fragmented_payload_b },
            .full_payloads = .{ full_payload_a, full_payload_b },
        };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.gpa.free(fixture.fragmented_spans[1]);
        fixture.gpa.free(fixture.fragmented_spans[0]);
        fixture.gpa.free(fixture.full_storage_b);
        fixture.gpa.free(fixture.full_storage_a);
        fixture.gpa.free(fixture.fragmented_storage_b);
        fixture.gpa.free(fixture.fragmented_storage_a);
        fixture.gpa.free(fixture.sparse_storage_b);
        fixture.gpa.free(fixture.sparse_storage_a);
        fixture.gpa.free(fixture.terminal_output);
        fixture.gpa.free(fixture.encode_buffer);
        fixture.gpa.free(fixture.cells_b);
        fixture.gpa.free(fixture.cells_a);
    }

    fn spans(fixture: *const Fixture, workload: Workload, variant: usize) []const schema.frame.Span {
        return switch (workload) {
            .one_cell => &fixture.sparse_spans[variant],
            .fragmented => fixture.fragmented_spans[variant],
            .full_screen => &fixture.full_spans[variant],
        };
    }

    fn payloads(fixture: *const Fixture, workload: Workload) [2][]const u8 {
        return switch (workload) {
            .one_cell => fixture.sparse_payloads,
            .fragmented => fixture.fragmented_payloads,
            .full_screen => fixture.full_payloads,
        };
    }
};

fn frame(frame_id: u64, spans: []const schema.frame.Span) schema.frame.Frame {
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

fn fillEditor(cells: []core.ui.Cell, variant: u8) void {
    for (cells, 0..) |*cell, index| {
        const x = index % cols;
        const y = index / cols;
        cell.* = .{};
        cell.bytes[0] = 'a' + @as(u8, @intCast((x + y + variant) % 26));
        if (x < 5) {
            cell.style.fg = .{ .indexed = 8 };
        } else if ((x / 11 + y) % 5 == 0) {
            cell.style.fg = .{ .indexed = 12 };
        } else if ((x / 17 + y) % 7 == 0) {
            cell.style.fg = .{ .indexed = 10 };
            cell.style.flags.bold = true;
        }
    }
}

fn fillFragmentedSpans(spans: []schema.frame.Span, cells: []const core.ui.Cell) void {
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

const DamageContext = struct {
    gpa: std.mem.Allocator,
    acknowledged: []core.ui.Cell,
    current: []core.ui.Cell,
    damaged_rows: []bool,
    spans: []schema.frame.Span,
    changed_index: usize,

    fn init(gpa: std.mem.Allocator, fixture: *const Fixture, workload: Workload) !DamageContext {
        const acknowledged = try gpa.dupe(core.ui.Cell, fixture.cells_a);
        errdefer gpa.free(acknowledged);
        const current = try gpa.dupe(core.ui.Cell, fixture.cells_a);
        errdefer gpa.free(current);
        const damaged_rows = try gpa.alloc(bool, rows);
        errdefer gpa.free(damaged_rows);
        @memset(damaged_rows, false);
        if (workload == .full_screen) {
            @memcpy(current, fixture.cells_b);
            @memset(damaged_rows, true);
        } else {
            for (fixture.spans(workload, 1)) |span| {
                const start: usize = @intCast(span.start);
                @memcpy(current[start..][0..span.cells.len], span.cells);
                damaged_rows[start / cols] = true;
            }
        }
        const changed_index: usize = @intCast(fixture.spans(workload, 1)[0].start);
        const spans = try gpa.alloc(schema.frame.Span, schema.frame.max_span_count);
        return .{
            .gpa = gpa,
            .acknowledged = acknowledged,
            .current = current,
            .damaged_rows = damaged_rows,
            .spans = spans,
            .changed_index = changed_index,
        };
    }

    fn deinit(context: *DamageContext) void {
        context.gpa.free(context.spans);
        context.gpa.free(context.damaged_rows);
        context.gpa.free(context.current);
        context.gpa.free(context.acknowledged);
    }
};

fn runDamage(context: *DamageContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.current[context.changed_index].bytes[0] = if (iteration & 1 == 0) '0' else '1';
        const diff = backend.damage.collectSpans(.{
            .current = context.current,
            .acknowledged = context.acknowledged,
            .cols = cols,
            .damaged_rows = context.damaged_rows,
        }, context.spans);
        checksum +%= diff.scanned_cells + diff.span_count;
    }
    return checksum;
}

const FrameContext = struct {
    damage: DamageContext,
    encode_buffer: []u8,

    fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !FrameContext {
        var damage = try DamageContext.init(gpa, fixture, .fragmented);
        errdefer damage.deinit();
        const encode_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        return .{ .damage = damage, .encode_buffer = encode_buffer };
    }

    fn deinit(context: *FrameContext) void {
        context.damage.gpa.free(context.encode_buffer);
        context.damage.deinit();
    }

    fn encode(context: *FrameContext) ![]const u8 {
        const diff = backend.damage.collectSpans(.{
            .current = context.damage.current,
            .acknowledged = context.damage.acknowledged,
            .cols = cols,
            .damaged_rows = context.damage.damaged_rows,
        }, context.damage.spans);
        return schema.encodePaneFrame(
            context.encode_buffer,
            frame(2, context.damage.spans[0..diff.span_count]),
        );
    }
};

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

const HistoryInputContext = struct {
    scanner: backend.history.terminal.InputScanner = .{},
};

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

const EncodeContext = struct {
    fixture: *Fixture,
    workload: Workload,
};

fn runEncode(context: *EncodeContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        const spans = context.fixture.spans(context.workload, iteration & 1);
        const payload = try schema.encodePaneFrame(context.fixture.encode_buffer, frame(2, spans));
        checksum +%= payload.len;
        checksum +%= payload[payload.len - 1];
    }
    return checksum;
}

const DecodeContext = struct {
    payloads: [2][]const u8,
};

fn runDecode(context: *DecodeContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        const message = try schema.decodeServer(context.payloads[iteration & 1]);
        const decoded = message.pane_frame;
        checksum +%= decoded.encoded_spans.len + decoded.span_count + decoded.frame_id;
    }
    return checksum;
}

const PipelineContext = struct {
    screen: frontend.term.Screen,
    payloads: [2][]const u8,
    output: []u8,

    fn init(gpa: std.mem.Allocator, fixture: *Fixture, workload: Workload) !PipelineContext {
        var screen = try frontend.term.Screen.init(gpa, cols, rows);
        errdefer screen.deinit();
        var writer = Io.Writer.fixed(fixture.terminal_output);
        _ = try screen.flush(&writer);
        return .{
            .screen = screen,
            .payloads = fixture.payloads(workload),
            .output = fixture.terminal_output,
        };
    }

    fn deinit(context: *PipelineContext) void {
        context.screen.deinit();
    }
};

fn runPipeline(context: *PipelineContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        const message = try schema.decodeServer(context.payloads[iteration & 1]);
        const applied = try frontend.frame.apply(&context.screen, message.pane_frame);
        var writer = Io.Writer.fixed(context.output);
        const flushed = try context.screen.flush(&writer);
        checksum +%= applied.cells + flushed.cells + flushed.scanned + flushed.bytes;
    }
    return checksum;
}

const OutboxContext = struct {
    outbox: *frontend.client.Outbox,
    buffer: [4096]u8 = undefined,

    fn init(gpa: std.mem.Allocator) !OutboxContext {
        const outbox = try gpa.create(frontend.client.Outbox);
        outbox.* = .{};
        return .{ .outbox = outbox };
    }

    fn deinit(context: *OutboxContext, gpa: std.mem.Allocator) void {
        gpa.destroy(context.outbox);
    }
};

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

const KeybindAction = enum(u8) { detach, palette };
const KeybindBinding = frontend.keybind.Binding(KeybindAction, 4);
const KeybindRouter = frontend.keybind.Router(KeybindAction, 16, 4, 64, 32);

const KeybindContext = struct {
    router: KeybindRouter,
    checksum: u64 = 0,

    fn init() !KeybindContext {
        const ctrl_b = try frontend.keybind.parseKey("ctrl+b");
        const d = try frontend.keybind.parseKey("d");
        const p = try frontend.keybind.parseKey("p");
        var bindings: [2]KeybindBinding = undefined;
        bindings[0] = try .init(&.{ ctrl_b, d }, .detach);
        bindings[1] = try .init(&.{ ctrl_b, p }, .palette);
        return .{ .router = try .init(&bindings) };
    }

    pub fn forward(context: *KeybindContext, bytes: []const u8) !void {
        context.checksum +%= bytes.len;
        if (bytes.len != 0) {
            context.checksum +%= bytes[0];
        }
    }

    pub fn action(context: *KeybindContext, action_value: KeybindAction) !frontend.keybind.Control {
        context.checksum +%= @intFromEnum(action_value) + 1;
        return .continue_routing;
    }
};

fn runKeybind(context: *KeybindContext, iterations: usize) !u64 {
    const input = "cargo test\x02d";
    for (0..iterations) |iteration| {
        _ = try context.router.feed(input, iteration, context);
    }
    return context.checksum;
}

const LuaCallbackContext = struct {
    generation: *frontend.config.Generation,
    reference: frontend.action.CallbackRef,
    diagnostic: frontend.config.Diagnostic = .{},

    fn init(gpa: std.mem.Allocator, io: Io) !LuaCallbackContext {
        var diagnostic: frontend.config.Diagnostic = .{};
        const generation = try frontend.config.Generation.loadSource(
            gpa,
            io,
            "local t=require('telar'); return { api_version=2, client={ keybindings={ t.bind_global({'escape'}, function(ctx) return t.action.toggle_sidebar() end) } } }",
            "@benchmark.lua",
            1,
            &diagnostic,
        );
        return .{
            .generation = generation,
            .reference = generation.snapshot.bindings[0].action.lua_callback,
        };
    }

    fn deinit(context: *LuaCallbackContext) void {
        context.generation.deinit();
    }
};

fn runLuaCallback(context: *LuaCallbackContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const batch = try context.generation.invokeCallback(
            context.reference,
            .{
                .sidebar_visible = true,
                .tab_count = 8,
                .active_tab_index = 3,
                .pane_count = 4,
                .focused_pane_id = 7,
            },
            &context.diagnostic,
        );
        checksum +%= batch.len;
    }
    return checksum;
}

const CursorContext = struct {
    screen: frontend.term.Screen,
    output: []u8,

    fn init(gpa: std.mem.Allocator, output: []u8) !CursorContext {
        var screen = try frontend.term.Screen.init(gpa, cols, rows);
        errdefer screen.deinit();
        var writer = Io.Writer.fixed(output);
        _ = try screen.flush(&writer);
        return .{ .screen = screen, .output = output };
    }

    fn deinit(context: *CursorContext) void {
        context.screen.deinit();
    }
};

const sidebar_width = frontend.client.sidebar_width;

const ClientUiContext = struct {
    tabs: frontend.tabs.Model,
    screen: frontend.term.Screen,
    view: frontend.client.View,

    fn init(gpa: std.mem.Allocator, tab_count: usize) !ClientUiContext {
        std.debug.assert(tab_count >= 1 and tab_count <= frontend.tabs.max_tabs);
        var tabs = frontend.tabs.Model.init(gpa);
        errdefer tabs.deinit();
        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        try tabs.bootstrap(
            @enumFromInt(1),
            .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
            .{ .cols = cols - sidebar_width, .rows = rows - 2 },
        );
        for (1..tab_count) |index| {
            var label_buffer: [schema.max_tab_label_bytes]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buffer, "tab-{d}", .{index + 1});
            _ = try tabs.addCreated(.{
                .location = .{
                    .workspace = workspace,
                    .tab_id = @enumFromInt(index + 1),
                },
                .position = @intCast(index),
                .label = label,
                .root_pane_id = @enumFromInt(index + 1),
            }, .{ .cols = cols - sidebar_width, .rows = rows - 2 });
        }
        var screen = try frontend.term.Screen.init(gpa, cols, rows);
        errdefer screen.deinit();
        var view = try frontend.client.View.init(gpa, cols, rows);
        errdefer view.deinit();
        const model = &tabs.active().?.model;
        var compositor = frontend.multiplexer.Compositor.init(gpa);
        defer compositor.deinit();
        _ = try compositor.render(.{
            .model = model,
            .screen = &screen,
            .input = .{ .area = view.workbench(), .palette = view.palette() },
        });
        _ = try view.render(&screen, .{ .tabs = &tabs, .model = model, .force = true });
        return .{ .tabs = tabs, .screen = screen, .view = view };
    }

    fn deinit(context: *ClientUiContext) void {
        context.view.deinit();
        context.screen.deinit();
        context.tabs.deinit();
    }
};

fn runClientUi(context: *ClientUiContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.view.hovered = if (iteration & 1 == 0) .active_workspace else .toggle_workspace_list;
        context.view.invalidate();
        const stats = try context.view.render(&context.screen, .{
            .tabs = &context.tabs,
            .model = &context.tabs.active().?.model,
        });
        checksum +%= stats.scanned + stats.damaged;
    }
    return checksum;
}

fn runCursor(context: *CursorContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.screen.cursor = .{ .x = @intCast(iteration % cols), .y = @intCast(iteration % rows) };
        var writer = Io.Writer.fixed(context.output);
        const flushed = try context.screen.flush(&writer);
        checksum +%= flushed.bytes;
    }
    return checksum;
}

const PacerContext = struct {
    pacer: frontend.pace.Pacer = .{},
    now_ns: u64 = 0,
};

fn runPacer(context: *PacerContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        if (context.pacer.waitUntil(context.now_ns)) |deadline_ns| {
            context.now_ns = deadline_ns + 2 * std.time.ns_per_ms;
            context.pacer.record(context.now_ns, deadline_ns, 1);
        } else {
            context.pacer.record(context.now_ns, null, 1);
        }
        checksum +%= context.pacer.anchor_ns.?;
    }
    return checksum;
}

const LayoutContext = struct {
    layout: frontend.layout.Layout = .{},
    area: core.ui.Rect = .{ .w = cols, .h = rows },

    fn init() !LayoutContext {
        var context: LayoutContext = .{};
        try context.layout.addRoot(@enumFromInt(1));
        try context.layout.split(@enumFromInt(1), @enumFromInt(2), .horizontal);
        try context.layout.split(@enumFromInt(1), @enumFromInt(3), .vertical);
        try context.layout.split(@enumFromInt(2), @enumFromInt(4), .vertical);
        return context;
    }
};

fn runLayoutFocus(context: *LayoutContext, iterations: usize) !u64 {
    const directions = [_]frontend.layout.Direction{ .right, .down, .left, .up };
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        if (context.layout.focusDirection(directions[iteration & 3], context.area)) |pane_id| {
            checksum +%= schema.id.raw(pane_id);
        }
    }
    return checksum;
}

/// Composes one model over the whole host screen with the default palette,
/// the way the presenter does for a client without chrome.
fn composeFullScreen(compositor: *frontend.multiplexer.Compositor, model: *const frontend.multiplexer.Model, screen: *frontend.term.Screen) !frontend.multiplexer.CompositionResult {
    return compositor.render(.{
        .model = model,
        .screen = screen,
        .input = .{ .area = screen.back.area(), .palette = &frontend.theme.default_theme.palette },
    });
}

const MultiplexerContext = struct {
    model: frontend.multiplexer.Model,
    screen: frontend.term.Screen,
    compositor: frontend.multiplexer.Compositor,

    fn init(gpa: std.mem.Allocator) !MultiplexerContext {
        var model = frontend.multiplexer.Model.init(gpa);
        errdefer model.deinit();
        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        try model.addRoot(@enumFromInt(1), location, .{ .cols = cols, .rows = rows });
        const area: core.ui.Rect = .{ .w = cols, .h = rows };
        try model.split(@enumFromInt(1), @enumFromInt(2), location, .horizontal, area);
        try model.split(@enumFromInt(1), @enumFromInt(3), location, .vertical, area);
        try model.split(@enumFromInt(2), @enumFromInt(4), location, .vertical, area);
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            pane.buffer.setCell(0, 0, "x", 1, .{});
        }
        const screen = try frontend.term.Screen.init(gpa, cols, rows);
        return .{ .model = model, .screen = screen, .compositor = .init(gpa) };
    }

    fn deinit(context: *MultiplexerContext) void {
        context.compositor.deinit();
        context.screen.deinit();
        context.model.deinit();
    }
};

fn runMultiplexerCompose(context: *MultiplexerContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        _ = context.model.focusPane(@enumFromInt(iteration % 4 + 1));
        const composed = try composeFullScreen(&context.compositor, &context.model, &context.screen);
        checksum +%= composed.stats.cells + composed.stats.panes;
    }
    return checksum;
}

const IncrementalComposeContext = struct {
    model: frontend.multiplexer.Model,
    screen: frontend.term.Screen,
    compositor: frontend.multiplexer.Compositor,
    payloads: [2][]const u8,

    fn init(gpa: std.mem.Allocator, fixture: *const Fixture) !IncrementalComposeContext {
        var model = frontend.multiplexer.Model.init(gpa);
        errdefer model.deinit();
        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        try model.addRoot(@enumFromInt(1), location, .{ .cols = cols, .rows = rows });
        var screen = try frontend.term.Screen.init(gpa, cols, rows);
        errdefer screen.deinit();
        var compositor = frontend.multiplexer.Compositor.init(gpa);
        errdefer compositor.deinit();
        _ = try composeFullScreen(&compositor, &model, &screen);
        model.find(@enumFromInt(1)).?.applied_frame_id = 1;
        return .{
            .model = model,
            .screen = screen,
            .compositor = compositor,
            .payloads = fixture.sparse_payloads,
        };
    }

    fn deinit(context: *IncrementalComposeContext) void {
        context.compositor.deinit();
        context.screen.deinit();
        context.model.deinit();
    }
};

fn runIncrementalCompose(context: *IncrementalComposeContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |iteration| {
        context.model.find(@enumFromInt(1)).?.applied_frame_id = 1;
        const frame_view = (try schema.decodeServer(
            context.payloads[iteration & 1],
        )).pane_frame;
        _ = try context.model.applyFrame(frame_view);
        const composed = try composeFullScreen(&context.compositor, &context.model, &context.screen);
        checksum +%= composed.stats.cells + composed.stats.damaged_cells;
    }
    return checksum;
}

const GraphicsContext = struct {
    store: frontend.kitty.Store,
    model: frontend.multiplexer.Model,
    output: []u8,

    fn init(gpa: std.mem.Allocator, output: []u8) !GraphicsContext {
        var store = frontend.kitty.Store.init(gpa);
        errdefer store.deinit();
        var model = frontend.multiplexer.Model.init(gpa);
        errdefer model.deinit();
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.addRoot(pane_id, .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .{ .cols = cols, .rows = rows });
        const metadata: core.graphics.Image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = 64,
            .height = 64,
            .byte_len = 64 * 64 * 4,
        };
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
        var pixels: [64 * 64 * 4]u8 = undefined;
        for (&pixels, 0..) |*byte, index| byte.* = @truncate(index);
        try store.applyChunk(.{
            .pane_id = pane_id,
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = &pixels,
        });
        try store.applyPlacement(.{
            .pane_id = pane_id,
            .revision = 1,
            .placement = .{
                .key = metadata.key,
                .virtual_id = 1,
                .placement_id = 1,
                .x = 0,
                .y = 0,
            },
        });
        return .{ .store = store, .model = model, .output = output };
    }

    fn deinit(context: *GraphicsContext) void {
        context.model.deinit();
        context.store.deinit();
    }

    fn writer(context: *GraphicsContext) frontend.kitty.KittyGraphicsWriter {
        return .{
            .store = &context.store,
            .layout_snapshot = context.model.layoutSnapshot(.{ .w = cols, .h = rows }),
            .cell_width = 10,
            .cell_height = 20,
        };
    }
};

fn runGraphicsTransmission(context: *GraphicsContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var images = context.store.images.iterator();
        while (images.next()) |entry| entry.value_ptr.transmitted = false;
        var placements = context.store.placements.iterator();
        while (placements.next()) |entry| {
            entry.value_ptr.emitted_image_id = null;
            entry.value_ptr.dirty = true;
        }
        context.store.damage = true;
        var output = Io.Writer.fixed(context.output);
        var graphics_writer = context.writer();
        checksum +%= try graphics_writer.write(&output);
    }
    return checksum;
}

fn runGraphicsIdle(context: *GraphicsContext, iterations: usize) !u64 {
    context.store.damage = false;
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var output = Io.Writer.fixed(context.output);
        var graphics_writer = context.writer();
        checksum +%= try graphics_writer.write(&output);
    }
    return checksum;
}

/// A full inline delivery of one browser-frame-sized image: the media path's
/// unit of throughput. One op is every writer pass an unbounded budget needs
/// until the store goes idle, so the zlib variant includes its deflate.
const TransmitContext = struct {
    const width = 480;
    const height = 360;
    const raw_len = width * height * 4;

    gpa: std.mem.Allocator,
    store: frontend.kitty.Store,
    model: frontend.multiplexer.Model,
    output: []u8,

    fn init(gpa: std.mem.Allocator, zlib: bool) !TransmitContext {
        var store = frontend.kitty.Store.init(gpa);
        errdefer store.deinit();
        store.host_zlib = zlib;
        var model = frontend.multiplexer.Model.init(gpa);
        errdefer model.deinit();
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.addRoot(pane_id, .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        }, .{ .cols = cols, .rows = rows });

        // Browser-frame shape: flat fills, a gradient, and a text-like band
        // of sparse noise. Pure random would defeat the zlib variant, pure
        // flat would flatter it.
        const pixels = try gpa.alloc(u8, raw_len);
        defer gpa.free(pixels);
        var prng = std.Random.DefaultPrng.init(7);
        const random = prng.random();
        for (0..height) |y| {
            for (0..width) |x| {
                const index = (y * width + x) * 4;
                if (y % 40 < 28) {
                    pixels[index + 0] = @intCast(30 + (x * 40) / width);
                    pixels[index + 1] = 34;
                    pixels[index + 2] = 40;
                } else {
                    const value: u8 = if (random.uintLessThan(u8, 8) == 0) 220 else 24;
                    pixels[index + 0] = value;
                    pixels[index + 1] = value;
                    pixels[index + 2] = value;
                }
                pixels[index + 3] = 255;
            }
        }
        const metadata: core.graphics.Image = .{
            .key = .{ .image_id = 1, .generation = 1 },
            .format = .rgba,
            .width = width,
            .height = height,
            .byte_len = raw_len,
        };
        try store.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = metadata });
        try store.applyChunk(.{
            .pane_id = pane_id,
            .revision = 1,
            .key = metadata.key,
            .offset = 0,
            .bytes = pixels,
        });
        try store.applyPlacement(.{
            .pane_id = pane_id,
            .revision = 1,
            .placement = .{
                .key = metadata.key,
                .virtual_id = 1,
                .placement_id = 1,
                .x = 0,
                .y = 0,
            },
        });
        const output = try gpa.alloc(u8, 4 * 1024 * 1024);
        return .{ .gpa = gpa, .store = store, .model = model, .output = output };
    }

    fn deinit(context: *TransmitContext) void {
        context.gpa.free(context.output);
        context.model.deinit();
        context.store.deinit();
    }

    fn deliver(context: *TransmitContext) !u64 {
        var images = context.store.images.iterator();
        while (images.next()) |entry| {
            entry.value_ptr.transmitted = false;
            entry.value_ptr.incompressible = false;
        }
        var placements = context.store.placements.iterator();
        while (placements.next()) |entry| {
            entry.value_ptr.emitted_image_id = null;
            entry.value_ptr.dirty = true;
        }
        context.store.damage = true;
        var written: u64 = 0;
        while (context.store.damage) {
            var output = Io.Writer.fixed(context.output);
            var graphics_writer: frontend.kitty.KittyGraphicsWriter = .{
                .store = &context.store,
                .layout_snapshot = context.model.layoutSnapshot(.{ .w = cols, .h = rows }),
                .cell_width = 10,
                .cell_height = 20,
                .budget = std.math.maxInt(usize),
            };
            written += try graphics_writer.write(&output);
        }
        return written;
    }
};

fn runTransmitDelivery(context: *TransmitContext, iterations: usize) !u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| checksum +%= try context.deliver();
    return checksum;
}

const KgpIngestContext = struct {
    const width = 1920;
    const height = 1080;
    const raw_len = width * height * 4;
    const prefix = "\x1b_Ga=t,f=32,o=z,s=1920,v=1080,t=d,i=7,q=2,C=1;";
    const suffix = "\x1b\\";

    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    gpa: std.mem.Allocator,
    command: []u8,

    fn init(io: Io, gpa: std.mem.Allocator) !KgpIngestContext {
        const raw = try gpa.alloc(u8, raw_len);
        defer gpa.free(raw);
        for (raw, 0..) |*byte, index| byte.* = @truncate(index % 251);

        const compressed_buffer = try gpa.alloc(u8, raw_len + 1024);
        defer gpa.free(compressed_buffer);
        var output: Io.Writer = .fixed(compressed_buffer);
        var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor = try std.compress.flate.Compress.init(
            &output,
            &compression_buffer,
            .zlib,
            .fastest,
        );
        try compressor.writer.writeAll(raw);
        try compressor.finish();
        const compressed = output.buffered();

        const encoded_len = std.base64.standard.Encoder.calcSize(compressed.len);
        const command = try gpa.alloc(u8, prefix.len + encoded_len + suffix.len);
        errdefer gpa.free(command);
        @memcpy(command[0..prefix.len], prefix);
        _ = std.base64.standard.Encoder.encode(
            command[prefix.len..][0..encoded_len],
            compressed,
        );
        @memcpy(command[prefix.len + encoded_len ..], suffix);

        var terminal = try vt.Terminal.init(io, gpa, .{
            .cols = cols,
            .rows = rows,
            .kitty_image_storage_limit = core.graphics.max_image_bytes_per_screen,
            .kitty_image_loading_limits = .direct,
        });
        errdefer terminal.deinit(gpa);
        const stream = vt.TerminalStream.init(.{
            .allocator = gpa,
            .handler = terminal.vtHandler(),
        });
        return .{ .terminal = terminal, .stream = stream, .gpa = gpa, .command = command };
    }

    fn deinit(context: *KgpIngestContext) void {
        context.stream.deinit();
        context.terminal.deinit(context.gpa);
        context.gpa.free(context.command);
    }
};

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

/// One terminal-browser style frame at 4K crossing the runtime: the child
/// publishes a shared object, the media pipeline folds the envelope and lets
/// Ghostty VT copy and unlink it, and the attachment freezes the resident
/// generation for a local client. Each stage is timed on its own so the
/// child's publish cost can be subtracted from the ingest figure.
const SharedFrameContext = struct {
    const width = 3840;
    const height = 2160;
    const raw_len = width * height * 4;
    const control = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=3840,v=2160,t=s,i=7,p=1,C=1,q=2;";
    const trailer = "\x1b\\\x1b[?2026l";

    io: Io,
    gpa: std.mem.Allocator,
    pixels: []u8,
    size: core.schema.TerminalSize,
    /// Heap-allocated: the emulator stream keeps pointers into its terminal,
    /// so the pipeline must never move after `init`.
    pipeline: *backend.media.Pipeline,
    sequence: u64 = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    envelope: [256]u8 = undefined,
    envelope_len: usize = 0,

    const Sink = struct {
        pipeline: *backend.media.Pipeline,

        pub fn observe(sink: *Sink, bytes: []const u8) void {
            sink.pipeline.stream.nextSlice(bytes);
        }

        /// The bare pipeline measures the emulator's own shared-memory load;
        /// the pane-level single-copy path is exercised by the runtime tests.
        pub fn observeSharedFrame(_: *Sink, _: backend.media.SharedFrameView) bool {
            return false;
        }

        pub fn observeFileQuery(_: *Sink, _: backend.media.FileQueryView) bool {
            return false;
        }
    };

    fn init(io: Io, gpa: std.mem.Allocator) !SharedFrameContext {
        if (comptime builtin.os.tag == .windows or !builtin.link_libc) {
            return error.SharedMemoryUnavailable;
        }
        const pixels = try gpa.alloc(u8, raw_len);
        errdefer gpa.free(pixels);
        for (pixels, 0..) |*byte, index| byte.* = @truncate(index % 251);

        const size: core.schema.TerminalSize = .{
            .cols = cols,
            .rows = rows,
            .cell_width_px = width / cols,
            .cell_height_px = height / rows,
        };
        const pipeline = try gpa.create(backend.media.Pipeline);
        errdefer gpa.destroy(pipeline);
        const context: SharedFrameContext = .{
            .io = io,
            .gpa = gpa,
            .pixels = pixels,
            .size = size,
            .pipeline = pipeline,
        };
        try pipeline.init(.{
            .io = io,
            .allocator = gpa,
            .size = size,
            .storage_limit = core.graphics.max_image_bytes_per_screen,
            .payload_limit = core.graphics.max_encoded_chunk_bytes,
            .write_pty = null,
        });
        return context;
    }

    fn deinit(context: *SharedFrameContext) void {
        context.pipeline.deinit();
        context.gpa.destroy(context.pipeline);
        context.gpa.free(context.pixels);
    }

    /// The child's side of one frame: a fresh object, its size, one memcpy.
    fn publish(context: *SharedFrameContext) !void {
        context.sequence += 1;
        const name = try std.fmt.bufPrintZ(
            &context.name,
            "/tlrbench{x}-{x}",
            .{ @as(u32, @bitCast(std.c.getpid())), context.sequence },
        );
        context.name_len = name.len;
        const fd = std.c.shm_open(
            name,
            @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
            @as(u16, 0o600),
        );
        if (std.posix.errno(fd) != .SUCCESS) {
            return error.SharedMemoryUnavailable;
        }
        defer _ = std.c.close(fd);
        if (std.c.ftruncate(fd, @intCast(raw_len)) != 0) {
            return error.SharedMemoryUnavailable;
        }
        const map = try std.posix.mmap(
            null,
            raw_len,
            .{ .READ = true, .WRITE = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        defer std.posix.munmap(map);
        @memcpy(map[0..raw_len], context.pixels);

        const Encoder = std.base64.standard.Encoder;
        var encoded: [128]u8 = undefined;
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(name.len)], name);
        const envelope = try std.fmt.bufPrint(&context.envelope, "{s}{s}{s}", .{ control, payload, trailer });
        context.envelope_len = envelope.len;
    }

    fn unpublish(context: *SharedFrameContext) void {
        _ = std.c.shm_unlink(context.name[0..context.name_len :0]);
    }

    /// The runtime's media actor for one batch holding the published frame.
    fn ingest(context: *SharedFrameContext) !u64 {
        context.pipeline.queueOutput(context.envelope[0..context.envelope_len]);
        if (!context.pipeline.seal()) {
            return error.MediaBatchEmpty;
        }
        var stats: backend.media.Stats = .{};
        var sink: Sink = .{ .pipeline = context.pipeline };
        context.pipeline.processSealed(.{ .current_size = context.size, .stats = &stats }, &sink);
        context.pipeline.finishSealed();
        if (stats.forwarded_frames != 1 or stats.failed) {
            return error.SharedFrameNotForwarded;
        }
        const image = context.pipeline.terminal.screens.active.kitty_images.imageById(7) orelse
            return error.KgpImageMissing;
        return image.generation + image.data.len();
    }

    /// The freeze the send loop performs for a local client, then the unlink
    /// Ghostty would do after consuming it.
    fn freeze(context: *SharedFrameContext) !u64 {
        const name = backend.runtime.freezeSharedPixels(context.pixels) orelse
            return error.SharedMemoryUnavailable;
        _ = std.c.shm_unlink(name.sliceZ());
        return name.slice().len;
    }
};

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

const TextRasterContext = struct {
    const width = 480;
    const height = 80;

    gpa: std.mem.Allocator,
    rasterizer: frontend.text_rasterizer.Rasterizer,
    pixels: []u8,

    fn init(gpa: std.mem.Allocator) !TextRasterContext {
        var rasterizer = try frontend.text_rasterizer.Rasterizer.init();
        errdefer rasterizer.deinit();
        try rasterizer.setPixelHeight(15);
        const pixels = try gpa.alloc(u8, width * height * 4);
        @memset(pixels, 32);
        return .{ .gpa = gpa, .rasterizer = rasterizer, .pixels = pixels };
    }

    fn deinit(context: *TextRasterContext) void {
        context.gpa.free(context.pixels);
        context.rasterizer.deinit();
    }
};

fn runTextRaster(context: *TextRasterContext, iterations: usize) !u64 {
    const surface: frontend.text_rasterizer.Surface = .{
        .pixels = context.pixels,
        .width = TextRasterContext.width,
        .height = TextRasterContext.height,
    };
    const color: frontend.text_rasterizer.Color = .{
        .red = 220,
        .green = 230,
        .blue = 240,
    };
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        checksum +%= try context.rasterizer.drawText(surface, 20, 18, "Build complete", color, 420);
        checksum +%= try context.rasterizer.drawText(surface, 20, 38, "Open the rendered result", color, 420);
        checksum +%= try context.rasterizer.drawText(surface, 20, 58, "click to open", color, 420);
    }
    return checksum +% context.pixels[context.pixels.len / 2];
}

fn execute(writer: *Io.Writer, io: Io, gpa: std.mem.Allocator, config: Config, fixture: *Fixture) !void {
    var case_index: usize = 0;

    inline for (workloads) |workload| {
        const case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            var context = try DamageContext.init(gpa, fixture, workload);
            defer context.deinit();
            try writeResult(writer, config, case, try measure(io, config, &context, runDamage));
        }
    }

    var frame_case = cases[case_index];
    case_index += 1;
    if (config.includes(frame_case.name)) {
        var context = try FrameContext.init(gpa, fixture);
        defer context.deinit();
        frame_case.payload_bytes_per_op = (try context.encode()).len;
        try writeResult(writer, config, frame_case, try measure(io, config, &context, runFrame));
    }

    const history_input_case = cases[case_index];
    case_index += 1;
    if (config.includes(history_input_case.name)) {
        var context: HistoryInputContext = .{};
        try writeResult(
            writer,
            config,
            history_input_case,
            try measure(io, config, &context, runHistoryInput),
        );
    }

    inline for (workloads) |workload| {
        var case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            const payloads = fixture.payloads(workload);
            case.payload_bytes_per_op = (payloads[0].len + payloads[1].len) / 2;
            var context: EncodeContext = .{ .fixture = fixture, .workload = workload };
            try writeResult(writer, config, case, try measure(io, config, &context, runEncode));
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
            try writeResult(writer, config, case, try measure(io, config, &context, runDecode));
        }
    }

    inline for (workloads) |workload| {
        var case = cases[case_index];
        case_index += 1;
        if (config.includes(case.name)) {
            const payloads = fixture.payloads(workload);
            case.payload_bytes_per_op = (payloads[0].len + payloads[1].len) / 2;
            var context = try PipelineContext.init(gpa, fixture, workload);
            defer context.deinit();
            try writeResult(writer, config, case, try measure(io, config, &context, runPipeline));
        }
    }

    const outbox_case = cases[case_index];
    case_index += 1;
    if (config.includes(outbox_case.name)) {
        var context = try OutboxContext.init(gpa);
        defer context.deinit(gpa);
        try writeResult(writer, config, outbox_case, try measure(io, config, &context, runOutboxInput));
    }

    const keybind_case = cases[case_index];
    case_index += 1;
    if (config.includes(keybind_case.name)) {
        var context = try KeybindContext.init();
        try writeResult(writer, config, keybind_case, try measure(io, config, &context, runKeybind));
    }

    const lua_callback_case = cases[case_index];
    case_index += 1;
    if (config.includes(lua_callback_case.name)) {
        var context = try LuaCallbackContext.init(gpa, io);
        defer context.deinit();
        try writeResult(
            writer,
            config,
            lua_callback_case,
            try measure(io, config, &context, runLuaCallback),
        );
    }

    const pacer_case = cases[case_index];
    case_index += 1;
    if (config.includes(pacer_case.name)) {
        var context: PacerContext = .{};
        try writeResult(writer, config, pacer_case, try measure(io, config, &context, runPacer));
    }

    const cursor_case = cases[case_index];
    case_index += 1;
    if (config.includes(cursor_case.name)) {
        var context = try CursorContext.init(gpa, fixture.terminal_output);
        defer context.deinit();
        try writeResult(writer, config, cursor_case, try measure(io, config, &context, runCursor));
    }

    inline for (client_ui_tab_counts) |tab_count| {
        const client_ui_case = cases[case_index];
        case_index += 1;
        if (config.includes(client_ui_case.name)) {
            var context = try ClientUiContext.init(gpa, tab_count);
            defer context.deinit();
            try writeResult(
                writer,
                config,
                client_ui_case,
                try measure(io, config, &context, runClientUi),
            );
        }
    }

    const layout_case = cases[case_index];
    case_index += 1;
    if (config.includes(layout_case.name)) {
        var context = try LayoutContext.init();
        try writeResult(writer, config, layout_case, try measure(io, config, &context, runLayoutFocus));
    }

    const multiplexer_case = cases[case_index];
    case_index += 1;
    if (config.includes(multiplexer_case.name)) {
        var context = try MultiplexerContext.init(gpa);
        defer context.deinit();
        try writeResult(
            writer,
            config,
            multiplexer_case,
            try measure(io, config, &context, runMultiplexerCompose),
        );
    }

    const incremental_case = cases[case_index];
    case_index += 1;
    if (config.includes(incremental_case.name)) {
        var context = try IncrementalComposeContext.init(gpa, fixture);
        defer context.deinit();
        try writeResult(
            writer,
            config,
            incremental_case,
            try measure(io, config, &context, runIncrementalCompose),
        );
    }

    var kgp_case = cases[case_index];
    case_index += 1;
    if (config.includes(kgp_case.name)) {
        var context = try KgpIngestContext.init(io, gpa);
        defer context.deinit();
        kgp_case.payload_bytes_per_op = context.command.len;
        try writeResult(
            writer,
            config,
            kgp_case,
            try measure(io, config, &context, runKgpIngest),
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
            try writeResult(
                writer,
                config,
                shared_publish_case,
                try measure(io, config, &context, runSharedFramePublish),
            );
        }
        if (config.includes(shared_ingest_case.name)) {
            try writeResult(
                writer,
                config,
                shared_ingest_case,
                try measure(io, config, &context, runSharedFrameIngest),
            );
        }
        if (config.includes(shared_freeze_case.name)) {
            try writeResult(
                writer,
                config,
                shared_freeze_case,
                try measure(io, config, &context, runSharedFrameFreeze),
            );
        }
    }

    var graphics_context = try GraphicsContext.init(gpa, fixture.terminal_output);
    defer graphics_context.deinit();
    var graphics_transmit_case = cases[case_index];
    case_index += 1;
    if (config.includes(graphics_transmit_case.name)) {
        var output = Io.Writer.fixed(fixture.terminal_output);
        var graphics_writer = graphics_context.writer();
        graphics_transmit_case.payload_bytes_per_op = try graphics_writer.write(&output);
        try writeResult(
            writer,
            config,
            graphics_transmit_case,
            try measure(io, config, &graphics_context, runGraphicsTransmission),
        );
    }
    const graphics_idle_case = cases[case_index];
    case_index += 1;
    if (config.includes(graphics_idle_case.name)) {
        try writeResult(
            writer,
            config,
            graphics_idle_case,
            try measure(io, config, &graphics_context, runGraphicsIdle),
        );
    }

    inline for ([_]bool{ false, true }) |zlib| {
        var transmit_case = cases[case_index];
        case_index += 1;
        if (config.includes(transmit_case.name)) {
            var context = try TransmitContext.init(gpa, zlib);
            defer context.deinit();
            transmit_case.payload_bytes_per_op = try context.deliver();
            try writeResult(
                writer,
                config,
                transmit_case,
                try measure(io, config, &context, runTransmitDelivery),
            );
        }
    }

    const text_raster_case = cases[case_index];
    case_index += 1;
    if (config.includes(text_raster_case.name)) {
        var context = try TextRasterContext.init(gpa);
        defer context.deinit();
        try writeResult(
            writer,
            config,
            text_raster_case,
            try measure(io, config, &context, runTextRaster),
        );
    }
    std.debug.assert(case_index == cases.len);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = Config.parse(args) catch |err| switch (err) {
        error.HelpRequested => {
            try Io.File.stdout().writeStreamingAll(init.io, usage);
            return;
        },
        else => {
            try Io.File.stderr().writeStreamingAll(init.io, usage);
            return err;
        },
    };

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

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

    try execute(writer, init.io, gpa.allocator(), config, &fixture);
    try writer.flush();
}
