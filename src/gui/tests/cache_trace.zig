//! Drives the native client's hot paths through `GuiAdapter.update` and
//! `draw` as the host does, and marks one window per event for the
//! touchrange Valgrind tool, which records the bytes of `Client` and
//! `GuiAdapter` each window reads or writes. Natively the marks are no-ops,
//! so the test only checks the loop.
//! Measurement: docs/performance/client-model-cache/README.md.
const client = @import("telar-client");
const core = @import("telar-core");
const cellgrid = @import("cellgrid");
const std = @import("std");
const touchtrace = @import("touchtrace");
const GuiAdapter = @import("../GuiAdapter.zig");
const Session = @import("Session.zig");
const input_support = @import("input_support.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const Range = enum(usize) {
    client = 0,
    adapter = 1,
    pane = 2,
};

const Trace = enum(usize) {
    warm_iterations = 6,
    frame_payload = 8192,
    screen_cells = 256,
};

test "cache trace: frame, key and draw events through the native event loop" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();

    const gui = session.gui;
    const app = &gui.app;
    const pane = app.model.panes.find(Session.pane_id) orelse return error.MissingPane;
    var wire: Wire = .{};
    var frame: Frame = .{};
    try frame.receive(session, &wire, false);

    touchtrace.dumpLayout(client.Client, "Client");
    touchtrace.dumpLayout(GuiAdapter, "GuiAdapter");
    touchtrace.register(@intFromEnum(Range.client), app);
    touchtrace.register(@intFromEnum(Range.adapter), gui);
    touchtrace.register(@intFromEnum(Range.pane), pane);

    const warm_iterations = @intFromEnum(Trace.warm_iterations);
    for (0..warm_iterations + 1) |iteration| {
        const traced = iteration == warm_iterations;
        try frame.receive(session, &wire, traced);

        touchtrace.start(traced);
        try input_support.accept(gui, .{
            .key = .{
                .code = .{
                    .char = .init("x"),
                },
            },
        });
        try input_support.pump(gui);
        touchtrace.stop(traced, "key/input");
        try finish(session, &wire, traced, "key");
    }

    try std.testing.expectEqual(frame.id, pane.applied_frame_id);
    var digest: [Sha256.digest_length]u8 = undefined;
    wire.hasher.final(&digest);
    touchtrace.reportOutput(&digest, wire.messages, 0);
}

/// Everything the runtime received, the oracle a traced change must keep.
const Wire = struct {
    hasher: Sha256 = .init(.{}),
    messages: u64 = 0,
};

/// The incremental frames the runtime sends, one changed cell each.
const Frame = struct {
    id: u64 = 0,
    payload: [@intFromEnum(Trace.frame_payload)]u8 = undefined,

    /// Decodes one frame into the transport's slot as the read worker does,
    /// then delivers it through the native inbox.
    fn receive(self: *Frame, session: *Session, wire: *Wire, traced: bool) !void {
        const app = &session.gui.app;
        const pane = app.model.panes.find(Session.pane_id).?;
        var cells: [@intFromEnum(Trace.screen_cells)]cellgrid.Cell = @splat(.{});
        const count = pane.buffer.cells.len;
        if (count > cells.len) {
            return error.TestScreenTooLarge;
        }

        const base_frame_id = self.id;
        self.id += 1;
        cells[0].bytes[0] = 'A' + @as(u8, @intCast(self.id % 26));
        const bytes = try core.encodePaneFrame(
            &self.payload,
            .{
                .pane_id = Session.pane_id,
                .frame_id = self.id,
                .base_frame_id = base_frame_id,
                .cols = pane.buffer.w,
                .rows = pane.buffer.h,
                .cursor = .{
                    .visible = true,
                    .x = 1,
                    .y = 0,
                },
                .scroll = .{
                    .total_rows = pane.buffer.h,
                    .offset = 0,
                },
                .spans = &.{.{
                    .start = 0,
                    .cells = if (base_frame_id == 0) cells[0..count] else cells[0..1],
                }},
            },
        );

        const transport = &app.runtime_transport;
        _ = transport.beginRead();
        touchtrace.start(traced);
        try transport.received.decodeInto(app.io, bytes);
        touchtrace.stop(traced, "frame/read_worker");

        try session.gui.driver.inbox.post(.{
            .client = .{
                .server = &transport.received,
            },
        });
        try update(session, traced, "frame/server");
        try finish(session, wire, traced, "frame");
    }
};

/// Completes every write the event started, then draws and presents as the
/// host does at its next vsync.
fn finish(session: *Session, wire: *Wire, traced: bool, phase: []const u8) !void {
    var label_buffer: [@intFromEnum(Label.bytes)]u8 = undefined;
    while (session.pending) |bytes| {
        wire.hasher.update(bytes);
        wire.messages += 1;
        session.pending = null;
        try session.gui.driver.inbox.post(.{
            .client = .{
                .sent = {},
            },
        });
        try update(session, traced, try std.fmt.bufPrintZ(&label_buffer, "{s}/sent", .{phase}));
    }

    touchtrace.start(traced);
    const token = try session.draw();
    touchtrace.stop(traced, try std.fmt.bufPrintZ(&label_buffer, "{s}/draw", .{phase}));
    if (token == 0) {
        return;
    }

    try session.gui.driver.inbox.post(.{
        .presented = .{
            .token = token,
            .delivered = true,
        },
    });
    try update(session, traced, try std.fmt.bufPrintZ(&label_buffer, "{s}/presented", .{phase}));
}

const Label = enum(usize) {
    bytes = 64,
};

fn update(session: *Session, traced: bool, label: [:0]const u8) !void {
    touchtrace.start(traced);
    const status = try session.gui.update();
    touchtrace.stop(traced, label);
    try std.testing.expectEqual(@as(?u8, null), status);
}
