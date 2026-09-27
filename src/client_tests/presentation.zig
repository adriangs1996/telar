//! Client integration tests for presentation: observations, the single
//! presentation flight and the frames it acknowledges.
const cellgrid = @import("cellgrid");
const client_module = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");

test "presentation folds repeated observations into one draw task" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const next_token = client.presentation.next_token;

    _ = try data.client_diagnostic.set(&client.model, "first revision", .{});
    _ = try data.client_diagnostic.set(&client.model, "second revision", .{});
    try harness.present();

    try std.testing.expectEqual(next_token + 1, client.presentation.next_token);
    try std.testing.expect(client.presentation.active == null);
    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);

    try harness.present();

    try std.testing.expectEqual(next_token + 1, client.presentation.next_token);
}

test "host input presentation state schedules only through observation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    var router = try client_module.key_router.build(client.routerConfig());
    const model_version = client.model.version();

    const decision = router.routeEvent(.{
        .key = router.prefix.?,
        .raw = "",
        .now_ns = 0,
    }, .{
        .captures_keys = data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)),
    });

    try std.testing.expect(decision == .pending);
    try std.testing.expect(router.prefixPending());
    try std.testing.expectEqualDeep(model_version, client.model.version());
    try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
}

test "host pointer shape follows semantic hover through paced presentation" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    var payload: [128]u8 = undefined;
    const cells = [_]cellgrid.Cell{.{}};
    for ([_]core.PointerShape{ .text, .wait, .zoom_in }, 0..) |shape, index| {
        const encoded = try core.encodePaneFrame(&payload, .{
            .pane_id = ClientHarness.bootstrap_pane,
            .frame_id = index + 1,
            .base_frame_id = index,
            .cols = 1,
            .rows = 1,
            .pointer_shape = shape,
            .scroll = .{ .total_rows = 1, .offset = 0 },
            .spans = if (index == 0) &.{.{ .start = 0, .cells = &cells }} else &.{},
        });
        _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(encoded));
        try harness.settleModelPresentation();
        try std.testing.expectEqual(shape, presentedPointerShape(&harness, ClientHarness.bootstrap_pane).?);
    }

    _ = try client_module.actions.executeAction(client, .enter_copy_mode, .effect);
    try harness.settleModelPresentation();
    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = .plain(.escape) });
    try std.testing.expect(!data.copy_mode.isActive(&client.model));
    try harness.settleModelPresentation();
    try std.testing.expectEqual(core.PointerShape.zoom_in, presentedPointerShape(&harness, ClientHarness.bootstrap_pane).?);
}

test "presentation flushes an explicit empty model before bootstrap" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    const client = harness.client;

    try std.testing.expect(client.model.tabs.activeSlot() == null);
    _ = try data.client_diagnostic.set(&client.model, "pre-bootstrap revision", .{});
    try harness.settleModelPresentation();

    try std.testing.expectEqualDeep(client.model.version(), client.presentation.delivered.model);
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.frame.pane_count);
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.frame.cell_count);
}

test "frame ACKs advance while a presentation token is still held" {
    for ([_]bool{ false, true }) |fail| {
        var harness: ClientHarness = undefined;
        try harness.init();
        defer harness.deinit();
        try harness.bootstrap();
        try harness.settleModelPresentation();
        const client = harness.client;
        const pane = client.model.panes.find(ClientHarness.bootstrap_pane).?;
        try receiveCellFrame(&harness, 1);
        var wire: [1024]u8 = undefined;
        try std.testing.expectEqual(@as(u64, 1), (try harness.nextClientMessage(&wire)).frame_ack.frame_id);
        try finishWrites(&harness);
        const before = client.presentation.delivered;
        // A window sealed the frame and is still writing it.
        const observation: client_module.Observation = .{
            .model = client.model.version(),
            .geometry_revision = data.workbench.region(&client.model).revision,
        };
        _ = client.presentation.observe(observation);
        const token = try client.presentation.begin(.{
            .observation = observation,
            .commit = data.presentation_delivery.capture(&client.model, client.model.tabs.active),
        });
        try std.testing.expectEqual(@as(u64, 1), pane.pending_frame_id);
        try std.testing.expectEqualDeep(before, client.presentation.delivered);
        try receiveCellFrame(&harness, 2);
        try std.testing.expectEqual(@as(u64, 2), (try harness.nextClientMessage(&wire)).frame_ack.frame_id);
        try finishWrites(&harness);
        try std.testing.expect(client.presentation.active != null);
        try std.testing.expectEqualStrings("B", pane.buffer.cells[0].text());
        if (fail) {
            try std.testing.expect(client.presentation.complete(token, .failed) == null);
            try std.testing.expect(client.presentation.preparation_invalid);
        } else {
            const delivery = client.presentation.complete(token, .delivered).?;
            try client_module.presentation_delivery.apply(&client.model, delivery.commit);
        }

        try std.testing.expectEqual(@as(u64, 2), pane.pending_frame_id);
        try std.testing.expectEqual(@as(usize, 0), client.model.to_runtime.len);
        try std.testing.expect(client.presentation.active == null);
    }
}

/// Completes the runtime writes in flight without presenting, as a window
/// whose frame is still being written does.
fn finishWrites(harness: *ClientHarness) !void {
    const outbox = &harness.client.model.to_runtime;
    while (outbox.inFlight() or outbox.len != 0) {
        const message = try harness.receiveClient();
        if (message != .sent) {
            return error.UnexpectedEvent;
        }

        _ = try harness.client.update(message);
    }

    try harness.deliverHostEffects();
}

fn receiveCellFrame(harness: *ClientHarness, frame_id: u64) !void {
    var cells: [4]cellgrid.Cell = @splat(.{});
    cells[0].bytes[0] = if (frame_id == 1) 'A' else 'B';
    var wire: [1024]u8 = undefined;
    const payload = try core.encodePaneFrame(&wire, .{
        .pane_id = ClientHarness.bootstrap_pane,
        .frame_id = frame_id,
        .base_frame_id = frame_id - 1,
        .cols = 2,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = if (frame_id == 1) &cells else cells[0..1] }},
    });
    _ = try client_module.runtime_messages.handleServerMessage(harness.client, try core.decodeServer(payload));
    @memset(&wire, 0xff);
}

/// The pointer shape the last presentation carried for one pane.
fn presentedPointerShape(harness: *const ClientHarness, pane_id: core.PaneId) ?core.PointerShape {
    const frame = &harness.adapter.frame;
    for (frame.panes[0..frame.pane_count]) |pane| {
        if (pane.id == pane_id) {
            return pane.pointer_shape;
        }
    }

    return null;
}
