//! Disposable single-pane client for protocol version 2.

const std = @import("std");
const core = @import("telar-core");
const frame_apply = @import("frame.zig");
const pace = @import("pace.zig");
const platform = @import("platform.zig");
const term = @import("term.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema.v2;
const diagnostics = core.diagnostics;

const input_chunk_size = 4096;

pub const Options = struct {
    arguments: []const []const u8,
    cwd: []const u8,
    endpoint: []const u8,
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
    flushes: u64 = 0,
    scanned_cells: u64 = 0,
    flushed_cells: u64 = 0,
    flushed_bytes: u64 = 0,
    max_pending_updates: u64 = 0,
    decode: diagnostics.Timing = .{},
    apply: diagnostics.Timing = .{},
    ack_send: diagnostics.Timing = .{},
    input_send: diagnostics.Timing = .{},
    flush: diagnostics.Timing = .{},
    draw_lateness: diagnostics.Timing = .{},
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
    resized: anyerror!void,
    server: anyerror![]u8,
    draw: anyerror!void,
    telemetry_tick: anyerror!void,
    telemetry_written: anyerror!void,
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

    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.pane_enter_sequence);
    try writer.flush();
    defer {
        writer.writeAll(platform.pane_leave_sequence) catch {};
        writer.flush() catch {};
    }

    const initial_size = terminalSize(&tty);
    var screen = try term.Screen.init(gpa, initial_size.cols, initial_size.rows);
    defer screen.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);

    const open_payload = try schema.encodeOpenPane(send_buffer, .{
        .request_id = 1,
        .size = initial_size,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);

    var select_storage: [6]ClientEvent = undefined;
    var select = Io.Select(ClientEvent).init(io, &select_storage);
    defer select.cancelDiscard();
    try select.concurrent(.resized, waitResize, .{ io, &watcher });
    try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var pane_id: u64 = 0;
    var applied_frame_id: u64 = 0;
    var input_started = false;
    var draw_pending = false;
    var pending_updates: usize = 0;
    var pending_frame_id: u64 = 0;
    var pacer: pace.Pacer = .{};
    var draw_due_ns: u64 = 0;
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    var metrics: ClientMetrics = .{ .started_ns = diagnostics.now(io) };
    while (true) switch (try select.await()) {
        .input => |result| {
            const chunk = try result;
            if (chunk.len == 0) return 0;
            if (pane_id != 0) {
                const send_started = diagnostics.now(io);
                const payload = try schema.encodePaneInput(send_buffer, .{
                    .pane_id = pane_id,
                    .bytes = chunk.slice(),
                });
                try connection.send(io, payload);
                if (comptime diagnostics.enabled) {
                    metrics.input_events += 1;
                    metrics.input_bytes += chunk.len;
                    metrics.input_send.observe(diagnostics.elapsed(send_started, diagnostics.now(io)));
                }
            }
            try select.concurrent(.input, readInput, .{io});
        },
        .resized => |result| {
            try result;
            if (pane_id != 0) {
                const payload = try schema.encodePaneResize(send_buffer, .{
                    .pane_id = pane_id,
                    .size = terminalSize(&tty),
                });
                try connection.send(io, payload);
            }
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
                    pane_id = opened.pane_id;
                    if (!input_started) {
                        try select.concurrent(.input, readInput, .{io});
                        input_started = true;
                    }
                },
                .pane_frame => |frame| {
                    if (pane_id == 0 or frame.pane_id != pane_id)
                        return error.UnexpectedPane;
                    if (frame.base_frame_id != 0 and frame.base_frame_id != applied_frame_id) {
                        const request = try schema.encodeRequestSnapshot(send_buffer, .{
                            .pane_id = pane_id,
                            .known_frame_id = applied_frame_id,
                        });
                        try connection.send(io, request);
                    } else {
                        const apply_started = diagnostics.now(io);
                        const applied = try frame_apply.apply(&screen, frame);
                        if (comptime diagnostics.enabled) {
                            metrics.frames += 1;
                            metrics.frame_cells += applied.cells;
                            metrics.frame_spans += applied.spans;
                            if (frame.base_frame_id == 0) metrics.snapshots += 1;
                            metrics.apply.observe(diagnostics.elapsed(apply_started, diagnostics.now(io)));
                        }
                        applied_frame_id = frame.frame_id;
                        pending_frame_id = applied_frame_id;
                        pending_updates += 1;
                        if (comptime diagnostics.enabled) {
                            metrics.max_pending_updates = @max(metrics.max_pending_updates, pending_updates);
                        }
                        if (!draw_pending) {
                            const wait_ns = pacer.waitFor(monotonic(io));
                            if (wait_ns == 0) {
                                try presentFrame(
                                    io,
                                    &screen,
                                    writer,
                                    connection,
                                    send_buffer,
                                    &metrics,
                                    pane_id,
                                    pending_frame_id,
                                );
                                pacer.record(monotonic(io), pending_updates);
                                pending_updates = 0;
                                pending_frame_id = 0;
                            } else {
                                pacer.noteThrottled();
                                draw_pending = true;
                                draw_due_ns = monotonic(io) +| wait_ns;
                                try select.concurrent(.draw, waitToDraw, .{ io, wait_ns });
                            }
                        }
                    }
                },
                .pane_exited => |exited| {
                    if (exited.pane_id != pane_id) return error.UnexpectedPane;
                    if (pending_updates != 0) {
                        try presentFrame(
                            io,
                            &screen,
                            writer,
                            connection,
                            send_buffer,
                            &metrics,
                            pane_id,
                            pending_frame_id,
                        );
                    }
                    return exitCode(exited);
                },
                .request_failed => |failure| {
                    std.debug.print("telar runtime: {s}\n", .{failure.message});
                    return error.RuntimeRequestFailed;
                },
                .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            }
            try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
        },
        .draw => |result| {
            try result;
            draw_pending = false;
            if (comptime diagnostics.enabled) {
                metrics.draw_lateness.observe(monotonic(io) -| draw_due_ns);
            }
            if (pending_updates != 0) {
                try presentFrame(
                    io,
                    &screen,
                    writer,
                    connection,
                    send_buffer,
                    &metrics,
                    pane_id,
                    pending_frame_id,
                );
                pacer.record(monotonic(io), pending_updates);
                pending_updates = 0;
                pending_frame_id = 0;
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
            const line = formatClientTelemetry(
                &telemetry_buffer,
                io,
                &metrics,
                &pacer,
                pane_id,
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

fn readInput(io: Io) anyerror!InputChunk {
    var chunk: InputChunk = .{};
    chunk.len = @intCast(try File.stdin().readStreaming(io, &.{&chunk.bytes}));
    return chunk;
}

fn waitResize(io: Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

fn receive(
    io: Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn presentFrame(
    io: Io,
    screen: *term.Screen,
    writer: *Io.Writer,
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    metrics: *ClientMetrics,
    pane_id: u64,
    frame_id: u64,
) !void {
    std.debug.assert(pane_id != 0 and frame_id != 0);
    try flushScreen(io, screen, writer, metrics);

    const ack_started = diagnostics.now(io);
    const ack = try schema.encodeFrameAck(send_buffer, .{
        .pane_id = pane_id,
        .frame_id = frame_id,
    });
    try connection.send(io, ack);
    if (comptime diagnostics.enabled) {
        metrics.ack_send.observe(diagnostics.elapsed(ack_started, diagnostics.now(io)));
    }
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

fn writeDiagnostics(
    io: Io,
    sink: *diagnostics.Sink,
    bytes: []const u8,
) anyerror!void {
    try sink.write(io, bytes);
}

fn formatClientTelemetry(
    buffer: []u8,
    io: Io,
    metrics: *const ClientMetrics,
    pacer: *const pace.Pacer,
    pane_id: u64,
    pending_updates: usize,
    draw_pending: bool,
) ![]const u8 {
    const now_ns = diagnostics.now(io);
    var writer = Io.Writer.fixed(buffer);
    try writer.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"client\"," ++
        "\"pane_id\":{d},\"pending_updates\":{d},\"draw_pending\":{d}," ++
        "\"input_events\":{d},\"input_bytes\":{d}," ++
        "\"server_messages\":{d},\"server_bytes\":{d}," ++
        "\"frames\":{d},\"frame_cells\":{d},\"frame_spans\":{d}," ++
        "\"snapshots\":{d},\"flushes\":{d},\"scanned_cells\":{d}," ++
        "\"flushed_cells\":{d}," ++
        "\"flushed_bytes\":{d},\"max_pending_updates\":{d}," ++
        "\"pacer_drawn\":{d},\"pacer_throttled\":{d},\"pacer_absorbed\":{d}", .{
        now_ns / std.time.ns_per_ms,
        diagnostics.elapsed(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        pane_id,
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
        metrics.flushes,
        metrics.scanned_cells,
        metrics.flushed_cells,
        metrics.flushed_bytes,
        metrics.max_pending_updates,
        pacer.stats.drawn,
        pacer.stats.throttled,
        pacer.stats.absorbed,
    });
    try writer.print(",\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"apply_avg_us\":{d},\"apply_max_us\":{d}," ++
        "\"ack_send_avg_us\":{d},\"ack_send_max_us\":{d}," ++
        "\"input_send_avg_us\":{d},\"input_send_max_us\":{d}," ++
        "\"flush_avg_us\":{d},\"flush_max_us\":{d}," ++
        "\"draw_late_avg_us\":{d},\"draw_late_max_us\":{d}}}\n", .{
        metrics.decode.average() / std.time.ns_per_us,
        metrics.decode.max_ns / std.time.ns_per_us,
        metrics.apply.average() / std.time.ns_per_us,
        metrics.apply.max_ns / std.time.ns_per_us,
        metrics.ack_send.average() / std.time.ns_per_us,
        metrics.ack_send.max_ns / std.time.ns_per_us,
        metrics.input_send.average() / std.time.ns_per_us,
        metrics.input_send.max_ns / std.time.ns_per_us,
        metrics.flush.average() / std.time.ns_per_us,
        metrics.flush.max_ns / std.time.ns_per_us,
        metrics.draw_lateness.average() / std.time.ns_per_us,
        metrics.draw_lateness.max_ns / std.time.ns_per_us,
    });
    return buffer[0..writer.end];
}

fn waitToDraw(io: Io, nanoseconds: u64) anyerror!void {
    try io.sleep(.fromNanoseconds(@intCast(nanoseconds)), .awake);
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

fn exitCode(message: schema.PaneExited) u8 {
    return switch (message.kind) {
        .exited => @intCast(@min(message.value, std.math.maxInt(u8))),
        .signaled => @intCast(@min(128 + message.value, std.math.maxInt(u8))),
    };
}

test "signal exits use the shell status convention" {
    try std.testing.expectEqual(@as(u8, 137), exitCode(.{
        .pane_id = 1,
        .kind = .signaled,
        .value = 9,
    }));
}
