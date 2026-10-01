const pacing = @import("pacing");
const ChromeFixture = @import("ChromeFixture.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Text = @import("../widgets/overlays/NotificationText.zig");
const animate = @import("animate");
const Clock = animate.FrameClock;

test "notification motion samples host time without squeezing text or changing the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.animation = .{};
    const id = data.notifications.publish(&fixture.model, 0, .{ .title = "Build complete", .message = "All checks passed", .level = .success }).id;
    const original = fixture.model.version();
    fixture.animation.?.begin(0);
    try fixture.paint();
    try std.testing.expectEqual(@as(usize, 0), fixture.overlays.presented().notifications.count);
    try std.testing.expectEqual(@as(u32, 17), fixture.animation.?.wakeupAfter(0));

    fixture.animation.?.begin(data.notifications.transition_duration_ns / 2);
    try fixture.prepare();
    const halfway = fixture.overlays.prepared().notifications.hits[0].bounds;
    try std.testing.expectEqual(@as(f32, 360), halfway.width);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.a <= 0.5 and quad.border_a <= 0.5);
    }
    fixture.present(false);
    try std.testing.expectEqual(@as(usize, 0), fixture.overlays.presented().notifications.count);

    fixture.animation.?.begin(data.notifications.transition_duration_ns * 2);
    try fixture.paint();
    const settled = fixture.overlays.presented().notifications.hits[0].bounds;
    try std.testing.expectEqual(halfway.width, settled.width);
    try std.testing.expectEqual(halfway.height, settled.height);
    try std.testing.expectApproxEqAbs(@as(f32, 6), halfway.x - settled.x, 0.001);
    try std.testing.expectEqual(@as(u32, 0), fixture.animation.?.wakeupAfter(fixture.animation.?.now_ns));
    try std.testing.expectEqual(original, fixture.model.version());

    _ = data.notifications.dismiss(&fixture.model, id, fixture.animation.?.now_ns);
    fixture.animation.?.begin(data.notifications.transition_duration_ns * 2 + data.notifications.transition_duration_ns / 2);
    try fixture.paint();
    try std.testing.expect(!fixture.overlays.presented().notifications.hits[0].enabled);
    fixture.animation.?.begin(data.notifications.transition_duration_ns * 4);
    try fixture.paint();
    try std.testing.expectEqual(@as(usize, 0), fixture.overlays.presented().notifications.count);
    try std.testing.expectEqual(@as(usize, 0), fixture.renderer.quads.items().len);
    try std.testing.expectEqual(@as(u32, 0), fixture.animation.?.wakeupAfter(fixture.animation.?.now_ns));
}

test "notification stack retargets from the current position and retires hidden motion" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.animation = .{};
    const first = data.notifications.publish(&fixture.model, 0, .{ .title = "First", .message = "Done" }).id;
    fixture.animation.?.begin(data.notifications.transition_duration_ns);
    try fixture.paint();
    const top = bounds(fixture, first).y;

    _ = data.notifications.publish(&fixture.model, 
        data.notifications.transition_duration_ns,
        .{
            .title = "Second",
            .message = "Done",
        },
    );
    fixture.animation.?.begin(data.notifications.transition_duration_ns);
    try fixture.paint();
    try std.testing.expectEqual(top, bounds(fixture, first).y);
    fixture.animation.?.begin(data.notifications.transition_duration_ns + 90 * std.time.ns_per_ms);
    try fixture.paint();
    const middle = bounds(fixture, first).y;
    try std.testing.expect(middle > top);
    fixture.animation.?.begin(data.notifications.transition_duration_ns * 3);
    try fixture.paint();
    try std.testing.expect(bounds(fixture, first).y > middle);
    try std.testing.expectEqual(@as(u32, 0), fixture.animation.?.wakeupAfter(fixture.animation.?.now_ns));

    fixture.size.cols = 10;
    fixture.size.rows = 3;
    fixture.animation.?.begin(data.notifications.transition_duration_ns * 4);
    try fixture.paint();
    try std.testing.expectEqual(@as(usize, 0), fixture.overlays.presented().notifications.count);
    try std.testing.expectEqual(@as(u32, 0), fixture.animation.?.wakeupAfter(fixture.animation.?.now_ns));
    for (fixture.overlays.notifications.motions) |motion| {
        try std.testing.expectEqual(data.notifications.Id.invalid, motion.id);
    }
}

test "native notification text wraps words newlines and graphemes with a bounded tail" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var text: Text = .{};
    try text.wrap(&canvas, .{ .text = "First paragraph\nSecond paragraph\nThird paragraph\nFourth", .width = 284 });
    try std.testing.expectEqual(@as(usize, 3), text.count);
    try std.testing.expectEqualStrings("First paragraph", text.line(0));
    try std.testing.expectEqualStrings("Second paragraph", text.line(1));
    try std.testing.expectEqualStrings("Third paragraph\u{2026}", text.line(2));
    // A copied card cannot retain a pointer into a previous stack temporary.
    const moved = text;
    text.tail = @splat('x');
    try std.testing.expectEqualStrings("Third paragraph\u{2026}", moved.line(2));

    try text.wrap(&canvas, .{ .text = "review e\u{301}界 words repeated to fill several lines and clip a long tail without breaking its UTF-8 text", .width = 92 });
    try std.testing.expectEqual(@as(usize, 3), text.count);
    for (0..text.count) |index| {
        const line = text.line(index);
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(try canvas.measure(.{ .text = line, .face = .sans, .size = .body }) <= 92);
    }
    try std.testing.expect(std.mem.endsWith(u8, text.line(2), "\u{2026}"));
}

test "notification controls use pixel edges and warm frames keep allocation bounds" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const id = data.notifications.publish(&fixture.model, 0, .{ .title = "Build complete", .message = "All checks passed" }).id;
    _ = data.notifications.advance(&fixture.model, data.notifications.transition_duration_ns);
    try fixture.paint();
    const card = bounds(fixture, id);
    const close = fixture.overlays.presented().notifications.hits[1].bounds;
    try std.testing.expectEqual(@as(f32, 26), close.width);
    const outside = fixture.pointer(.{ .kind = .press, .x = card.x - 0.01, .y = card.y + card.height / 2 });
    try std.testing.expect(!outside.consumed);
    _ = fixture.pointer(.{ .kind = .release, .x = 0, .y = 0 });
    const inside = fixture.pointer(.{ .kind = .press, .x = close.x + 0.01, .y = close.y + 0.01 });
    try std.testing.expectEqualDeep(client.Intent{ .notification_dismiss = id }, inside.intent);
    _ = fixture.pointer(.{ .kind = .release, .x = 0, .y = 0 });

    const atlas = &fixture.renderer.atlas.?;
    const calls = atlas.shape_calls;
    const version = atlas.version;
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = atlas.allocator;
    atlas.allocator = failure.allocator();
    defer atlas.allocator = allocator;
    const quad_allocator = fixture.renderer.quads.allocator;
    fixture.renderer.quads.allocator = failure.allocator();
    defer fixture.renderer.quads.allocator = quad_allocator;
    for (0..12) |_| {
        try fixture.paint();
    }
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(@as(usize, 0), failure.allocations);
}

test "GUI notification lifecycle wakes at semantic boundaries while the host owns frames" {
    var fixture = try ChromeFixture.init();
    defer fixture.deinit();
    const app = fixture.session.gui.app;
    const now = pacing.clock.monotonic(app.io);
    _ = try client.notifications.publishNotification(
        app,
        now,
        .{
            .title = "Ready",
            .message = "Done",
        },
    );
    try std.testing.expect(app.model.host.animation_frame_ns == null);
    try std.testing.expectEqual(now + data.notifications.transition_duration_ns, app.model.notification_scheduler.deadline_ns.load(.acquire));
    try std.testing.expect(Clock.default_interval_ns < data.notifications.transition_duration_ns);
}

fn bounds(fixture: *const Fixture, id: data.notifications.Id) Rect {
    const hits = &fixture.overlays.presented().notifications;
    for (hits.hits[0..hits.count]) |hit| {
        if (hit.namespace == 2 and (hit.action.intent == .notification_dismiss and hit.action.intent.notification_dismiss == id)) {
            return hit.bounds;
        }
    }

    unreachable;
}
