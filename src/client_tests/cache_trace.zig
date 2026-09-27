//! Drives the shared client's hot paths through the harness's event loop
//! and marks one window per event for the touchrange Valgrind tool, which
//! records the bytes of `Client` and `ClientHarness` each window reads or
//! writes. Natively the marks are no-ops, so the test only checks the loop.
//! Measurement: docs/performance/client-model-cache/README.md.
const cellgrid = @import("cellgrid");
const keyinput = @import("keyinput");
const client_module = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const ClientHarness = @import("ClientHarness.zig");
const touchtrace = @import("touchtrace");

const Range = enum(usize) {
    client = 0,
    adapter = 1,
    pane = 2,
};
const Sha256 = std.crypto.hash.sha2.Sha256;
const Trace = enum(usize) {
    warm_iterations = 6,
    tabs = 4,
    frame_payload = 64 * 1024,
    message = 4096,
    label = 64,
};

/// Everything the runtime received, the oracle a traced change must keep.
const Wire = struct {
    hasher: Sha256 = .init(.{}),
    messages: u64 = 0,
    buffer: [@intFromEnum(Trace.message)]u8 = undefined,
};

test "cache trace: frame, key and draw events through the terminal event loop" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();

    for (1..@intFromEnum(Trace.tabs)) |index| {
        _ = try harness.addInactiveTab(@enumFromInt(index + 1), @enumFromInt(index + 100));
    }

    const client = harness.client;
    const pane = client.model.panes.find(ClientHarness.bootstrap_pane) orelse return error.MissingPane;
    const cols: u16 = @intCast(@max(pane.buffer.w, 1));
    const rows: u16 = @intCast(@max(pane.buffer.h, 1));
    const key = try keyinput.chord.parseKey("x");

    touchtrace.dumpLayout(client_module.Client, "Client");
    touchtrace.dumpLayout(ClientHarness, "ClientHarness");
    touchtrace.register(@intFromEnum(Range.client), client);
    touchtrace.register(@intFromEnum(Range.adapter), &harness);
    touchtrace.register(@intFromEnum(Range.pane), pane);

    try client_module.runtime_io.startRuntimeRead(client);
    try harness.deliverHostEffects();

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
                .pane_id = ClientHarness.bootstrap_pane,
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

        touchtrace.start(traced);
        try harness.peer.send(std.testing.io, bytes);
        const event = try harness.inbox.receive();
        touchtrace.stop(traced, "frame/read_worker");
        try handleWindow(
            &harness,
            event,
            traced,
            "frame",
        );
        try drive(
            &harness,
            traced,
            "frame",
            &wire,
        );

        touchtrace.start(traced);
        _ = try client_module.key_routing.routeKeyInput(client, .{ .key = key });
        try harness.deliverHostEffects();
        try harness.present();
        touchtrace.stop(traced, "key/input");
        try drive(
            &harness,
            traced,
            "key",
            &wire,
        );
    }

    try std.testing.expectEqual(frame_id, pane.applied_frame_id);
    var digest: [Sha256.digest_length]u8 = undefined;
    wire.hasher.final(&digest);
    touchtrace.reportOutput(&digest, wire.messages, 0);
}

/// Handles events until the outbox is empty and the presentation caught up
/// with the model, reading every message the client wrote.
fn drive(harness: *ClientHarness, traced: bool, phase: []const u8, wire: *Wire) !void {
    const client = harness.client;
    while (!settled(client)) {
        const event = try harness.inbox.receive();
        if (event.client == .sent) {
            const bytes = try harness.peer.receive(std.testing.io, &wire.buffer);
            wire.hasher.update(bytes);
            wire.messages += 1;
        }

        try handleWindow(
            harness,
            event,
            traced,
            phase,
        );
    }

    try std.testing.expect(!client.model.to_runtime.inFlight());
}

fn settled(client: *const client_module.Client) bool {
    const model = &client.model;
    return !model.to_runtime.inFlight() and
        model.to_runtime.len == 0 and
        client.presentation.active == null and
        std.meta.eql(client.presentation.prepared.model, model.version());
}

/// One event as the harness's loop handles it: the client's update, its
/// host requests and one presentation.
fn handleWindow(harness: *ClientHarness, event: ClientHarness.Event, traced: bool, phase: []const u8) !void {
    var label_buffer: [@intFromEnum(Trace.label)]u8 = undefined;
    const label = try std.fmt.bufPrintZ(
        &label_buffer,
        "{s}/{s}",
        .{ phase, @tagName(event.client) },
    );

    touchtrace.start(traced);
    const status = try harness.client.update(event.client);
    try harness.deliverHostEffects();
    try harness.present();
    touchtrace.stop(traced, label);
    try std.testing.expect(status == null);
}
