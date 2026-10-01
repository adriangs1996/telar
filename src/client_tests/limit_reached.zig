const std = @import("std");
const core = @import("telar-core");
const client_module = @import("telar-client");
const ClientHarness = @import("ClientHarness.zig");

const bar_actions: core.LimitReach = .{
    .limit = .{
        .name = "bars.max_bar_actions",
        .noun = "click actions",
        .value = 4,
    },
    .requested = 17,
};

test "a client limit is shown once per interval, counts every reach and reaches the runtime folded" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    client_module.limit_reached.report(client, bar_actions);
    client_module.limit_reached.report(client, bar_actions);

    const reaches = &client.model.limit_reaches;
    const slot = reaches.find("bars.max_bar_actions").?;
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);

    const notice = client.model.notification_center.itemAt(0).?;
    try std.testing.expectEqualStrings(core.limit_reached.notice_title, notice.title());
    try std.testing.expectEqualStrings("bars.max_bar_actions: 17 click actions; limit 4", notice.message());

    try harness.settle();
    var buffer: [256]u8 = undefined;
    const first = try harness.nextClientMessage(&buffer);
    try std.testing.expect(first == .report_limit);
    try std.testing.expectEqualStrings("bars.max_bar_actions", first.report_limit.reach.limit.name);
    try std.testing.expectEqual(@as(u32, 1), first.report_limit.hits);

    // The reach inside the report interval waits; the next one after it
    // carries both.
    reaches.reported_ms[slot] = reaches.reported_ms[slot].? - core.limit_reached.report_interval_ms;
    client_module.limit_reached.report(client, bar_actions);
    try harness.settle();
    const folded = try harness.nextClientMessage(&buffer);
    try std.testing.expect(folded == .report_limit);
    try std.testing.expectEqual(@as(u32, 2), folded.report_limit.hits);
    try std.testing.expectEqual(@as(u8, 1), client.model.notification_center.count);
}

test "the adapter safety net reports capacity errors and returns the rest" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    try client_module.limit_reached.absorb(client, "window_draw", error.PresentationIdExhausted, .{
        .name = "render.frame_quad_budget",
        .noun = "quads",
        .value = 256,
    });
    try client_module.limit_reached.absorb(client, "window_draw", error.InboxFull, null);
    try std.testing.expectError(error.DeviceLost, client_module.limit_reached.absorb(client, "window_draw", error.DeviceLost, null));

    const reaches = &client.model.limit_reaches;
    try std.testing.expect(reaches.find("render.frame_quad_budget") != null);
    try std.testing.expect(reaches.find("InboxFull") != null);
    try std.testing.expectEqual(@as(usize, 2), reaches.count);
}
