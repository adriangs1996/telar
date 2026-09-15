const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const RingFades = @import("../widgets/RingFades.zig");
const FrameClock = @import("../animation/FrameClock.zig");
const Quad = @import("../render/Quad.zig").Quad;

test "a blocked pane animates without working agents and folds a rejected and late frame" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    _ = model.layout.focusPane(Session.pane_id);
    var agents: client.AgentSnapshot = .{};
    _ = try agents.replace(.{ .revision = 1, .agents = &.{.{
        .key = .{ .pane_id = second, .pane_generation = 1 },
        .location = Session.location,
        .pane_index = 2,
        .provider = .claude,
        .status = .blocked,
        .blocked_reason = .permission,
    }} });
    var projection = fixture.projection();
    projection.agents = &agents;
    const version = fixture.session.gui.app.model.version();
    const started_ns = std.time.ns_per_s;
    fixture.chrome.now_ns = started_ns;
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(f32, 0), try attentionOpacity(fixture.session.renderer.quads.items()));
    try std.testing.expect(fixture.chrome.animation.wakeupAfter(started_ns) > 0);

    fixture.chrome.now_ns = started_ns + RingFades.duration_ns / 2;
    try fixture.prepare(projection);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try attentionOpacity(fixture.session.renderer.quads.items()), 0.001);
    fixture.chrome.present(false);

    fixture.chrome.now_ns = started_ns + 4 * RingFades.duration_ns;
    try std.testing.expect(fixture.chrome.animation.due(fixture.chrome.now_ns));
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(f32, 1), try attentionOpacity(fixture.session.renderer.quads.items()));
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
    try std.testing.expectEqual(version, fixture.session.gui.app.model.version());

    _ = model.layout.focusPane(second);
    projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    try std.testing.expectError(error.MissingAttentionRing, attentionOpacity(fixture.session.renderer.quads.items()));
    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.rings.len);
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
}

test "hiding the only animated widget removes its frame deadline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.session.gui.app;
    _ = try app.model.reconcileAgentSnapshot(.{ .revision = 1, .agents = &.{.{
        .key = .{ .pane_id = Session.pane_id, .pane_generation = 1 },
        .location = Session.location,
        .pane_index = 1,
        .provider = .codex,
        .status = .working,
    }} });
    const version = app.model.version();
    try std.testing.expectEqual(.host, app.timers.animation_clock);
    try std.testing.expectEqual(.active, try client.controllers.sidebar_animations.synchronize(app));
    try std.testing.expect(!app.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(version, app.model.version());

    fixture.chrome.now_ns = 100 * std.time.ns_per_s;
    var projection = fixture.projection();
    try fixture.paint(projection);
    try std.testing.expect(fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns) > 0);

    try fixture.showSidebar(false);
    fixture.chrome.now_ns += std.time.ns_per_s;
    projection = fixture.projection();
    try fixture.paint(projection);
    _ = try client.controllers.sidebar_animations.synchronize(app);
    try std.testing.expect(!app.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
    try std.testing.expect(!fixture.chrome.animation.due(std.math.maxInt(u64)));

    try fixture.showSidebar(true);
    projection = fixture.projection();
    try fixture.paint(projection);
    try std.testing.expect(fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns) > 0);
}

test "native indeterminate progress paints each frame without model ticks and folds rejected frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.session.gui.app;
    const pane = app.model.workspace.findPane(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
    const version = app.model.version();
    fixture.chrome.now_ns = std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(fixture.chrome.now_ns + FrameClock.frame_interval_ns, fixture.chrome.animation.deadline_ns.?);
    const previous = try std.testing.allocator.dupe(Quad, fixture.session.renderer.quads.items());
    defer std.testing.allocator.free(previous);

    fixture.chrome.now_ns += FrameClock.frame_interval_ns;
    try fixture.prepare(fixture.projection());
    const next = fixture.session.renderer.quads.items();
    var changed = previous.len != next.len;
    for (previous[0..@min(previous.len, next.len)], next[0..@min(previous.len, next.len)]) |before, after| {
        changed = changed or !std.meta.eql(before, after);
    }

    try std.testing.expect(changed);
    fixture.chrome.present(false);
    fixture.chrome.now_ns += 8 * std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(fixture.chrome.now_ns + FrameClock.frame_interval_ns, fixture.chrome.animation.deadline_ns.?);
    try std.testing.expectEqual(version, app.model.version());
    try std.testing.expect(!app.sidebar_animation_scheduler.pending);
}

test "native paused failed and removed progress stop their frame clock" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    for ([_]core.PaneProgressState{ .pause, .@"error", .remove }) |state| {
        _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
        fixture.chrome.now_ns += std.time.ns_per_s;
        try fixture.paint(fixture.projection());
        try std.testing.expect(fixture.chrome.animation.deadline_ns != null);

        _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = state });
        fixture.chrome.now_ns += FrameClock.frame_interval_ns;
        try fixture.paint(fixture.projection());
        try std.testing.expectEqual(@as(?u64, null), fixture.chrome.animation.deadline_ns);
        try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
    }

    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.progress.len);
}

test "hiding native pane progress retires its retained motion and stops repainting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const second: core.TabId = @enumFromInt(2);
    _ = try model.workspace.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = second }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, model.hostSize());
    _ = model.workspace.select(Session.location.tab_id);
    const pane = model.workspace.findPane(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
    fixture.chrome.now_ns = std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(usize, 1), fixture.chrome.progress.len);
    try std.testing.expect(fixture.chrome.animation.deadline_ns != null);

    _ = model.workspace.select(second);
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.progress.len);
    try std.testing.expectEqual(@as(?u64, null), fixture.chrome.animation.deadline_ns);
    try std.testing.expect(!fixture.chrome.animation.due(std.math.maxInt(u64)));

    _ = model.workspace.select(Session.location.tab_id);
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(usize, 1), fixture.chrome.progress.len);
    try std.testing.expectEqual(fixture.chrome.now_ns + FrameClock.frame_interval_ns, fixture.chrome.animation.deadline_ns.?);
}

fn attentionOpacity(quads: []const Quad) !f32 {
    var alpha: ?f32 = null;
    for (quads) |quad| {
        if (quad.border == 2 and quad.a == 0) {
            if (alpha != null) {
                return error.DuplicateAttentionRing;
            }

            alpha = quad.border_a;
        }
    }

    return alpha orelse error.MissingAttentionRing;
}
