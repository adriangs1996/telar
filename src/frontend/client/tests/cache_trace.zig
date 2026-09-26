//! Drives the terminal client's hot paths through its real event loop and
//! marks one window per event for the touchrange Valgrind tool, which
//! records the bytes of `Client` and `TerminalAdapter` each window reads or
//! writes. Natively the marks are no-ops, so the test only checks the loop.
//! Measurement: docs/performance/client-model-cache/README.md.
const cellgrid = @import("cellgrid");
const client_module = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const TestHarness = @import("TestHarness.zig");
const TerminalAdapter = @import("../TerminalAdapter.zig");
const events = @import("../events.zig");
const EventResources = @import("../EventResources.zig");
const host_inputs = @import("../input/host_inputs.zig");
const host_effects = @import("../host/host_effects.zig");
const support = @import("support.zig");
const touch_trace = @import("touch_trace.zig");

const Range = touch_trace.Range;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Trace = enum(usize) {
    warm_iterations = 6,
    tabs = 4,
    frame_payload = 64 * 1024,
    message = 4096,
    label = 64,
};

test "cache trace: frame, key and draw events through the terminal event loop" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    for (1..@intFromEnum(Trace.tabs)) |index| {
        _ = try harness.addInactiveTab(@enumFromInt(index + 1), @enumFromInt(index + 100));
    }

    const client = harness.client;
    const terminal = harness.terminal;
    var heap = core.Heap.init(std.testing.allocator);
    const resources = support.clientEventResourcesForTest(&heap);
    const pane = client.model.panes.find(TestHarness.bootstrap_pane) orelse return error.MissingPane;
    const cols: u16 = @intCast(@max(pane.buffer.w, 1));
    const rows: u16 = @intCast(@max(pane.buffer.h, 1));

    touch_trace.dumpLayout(client_module.Client, "Client");
    touch_trace.dumpLayout(TerminalAdapter, "TerminalAdapter");
    touch_trace.register(Range.client, client);
    touch_trace.register(Range.adapter, terminal);
    touch_trace.register(Range.pane, pane);

    try client_module.runtime_io.startRuntimeRead(client);
    try host_effects.deliver(terminal);
    try host_inputs.scheduleRead(terminal);

    const screen = try std.testing.allocator.alloc(cellgrid.Cell, @as(usize, cols) * rows);
    defer std.testing.allocator.free(screen);
    @memset(screen, .{});
    const payload = try std.testing.allocator.alloc(u8, @intFromEnum(Trace.frame_payload));
    defer std.testing.allocator.free(payload);

    var frame_id: u64 = 0;
    var wire: Wire = .{};
    const warm_iterations = @intFromEnum(Trace.warm_iterations);
    for (0..warm_iterations + 1) |iteration| {
        const traced = iteration == warm_iterations;
        const column = iteration % cols;
        screen[column].bytes[0] = 'a' + @as(u8, @intCast(iteration));
        const base_frame_id = frame_id;
        frame_id += 1;
        const span: core.Span = if (base_frame_id == 0) .{
            .start = 0,
            .cells = screen,
        } else .{
            .start = @intCast(column),
            .cells = screen[column..][0..1],
        };

        const bytes = try core.encodePaneFrame(
            payload,
            .{
                .pane_id = TestHarness.bootstrap_pane,
                .frame_id = frame_id,
                .base_frame_id = base_frame_id,
                .cols = cols,
                .rows = rows,
                .scroll = .{
                    .total_rows = rows,
                    .offset = 0,
                },
                .spans = &.{span},
            },
        );

        touch_trace.start(traced);
        try harness.peer.send(std.testing.io, bytes);
        const event = try terminal.inbox.receive();
        touch_trace.stop(traced, "frame/read_worker");
        try handleWindow(
            terminal,
            event,
            resources,
            traced,
            "frame",
        );
        try drive(
            &harness,
            resources,
            traced,
            "frame",
            &wire,
        );

        touch_trace.start(traced);
        try harness.input_write.writeStreamingAll(std.testing.io, "x");
        const input = try terminal.inbox.receive();
        touch_trace.stop(traced, "key/read_worker");
        try handleWindow(
            terminal,
            input,
            resources,
            traced,
            "key",
        );
        try drive(
            &harness,
            resources,
            traced,
            "key",
            &wire,
        );
    }

    try std.testing.expectEqual(frame_id, pane.applied_frame_id);
    var digest: [Sha256.digest_length]u8 = undefined;
    wire.hasher.final(&digest);
    touch_trace.reportOutput(
        &digest,
        wire.messages,
        harness.sink.fullCount(),
    );
}

/// Everything the runtime received, the oracle a traced change must keep.
const Wire = struct {
    hasher: Sha256 = .init(.{}),
    messages: u64 = 0,
    buffer: [@intFromEnum(Trace.message)]u8 = undefined,
};

/// Handles events until the outbox is empty and the presentation caught up
/// with the model, reading every message the client wrote.
fn drive(harness: *TestHarness, resources: EventResources, traced: bool, phase: []const u8, wire: *Wire) !void {
    const client = harness.client;
    const terminal = harness.terminal;
    while (!settled(terminal)) {
        const event = try terminal.inbox.receive();
        if (event == .client and event.client == .sent) {
            const bytes = try harness.peer.receive(std.testing.io, &wire.buffer);
            wire.hasher.update(bytes);
            wire.messages += 1;
        }

        try handleWindow(
            terminal,
            event,
            resources,
            traced,
            phase,
        );
    }

    try std.testing.expect(!client.model.to_runtime.inFlight());
}

fn settled(terminal: *TerminalAdapter) bool {
    const model = &terminal.app.model;
    return !model.to_runtime.inFlight() and
        model.to_runtime.len == 0 and
        terminal.app.presentation.active == null and
        std.meta.eql(terminal.presenter.presentation_state.prepared.model, model.version());
}

fn handleWindow(terminal: *TerminalAdapter, event: TerminalAdapter.ClientEvent, resources: EventResources, traced: bool, phase: []const u8) !void {
    var label_buffer: [@intFromEnum(Trace.label)]u8 = undefined;
    const label = try std.fmt.bufPrintZ(
        &label_buffer,
        "{s}/{s}",
        .{ phase, eventName(event) },
    );

    touch_trace.start(traced);
    const outcome = try events.handle(terminal, event, resources);
    touch_trace.stop(traced, label);
    try std.testing.expect(outcome == .keep_running);
}

fn eventName(event: TerminalAdapter.ClientEvent) []const u8 {
    return switch (event) {
        .client => |message| @tagName(message),
        else => @tagName(event),
    };
}
