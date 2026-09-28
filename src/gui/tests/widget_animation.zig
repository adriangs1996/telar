const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const RingFades = @import("../widgets/RingFades.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;

test "a blocked pane animates without working agents and folds a rejected and late frame" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const tab = fixture.session.gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(20);
    try data.pane_split.split(&fixture.session.gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    _ = fixture.session.gui.app.model.tabs.layout[tab].focusPane(Session.pane_id);
    var agents: data.AgentSnapshot = .{};
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
    try std.testing.expectEqual(@as(f32, 0), try attentionOpacity(fixture.session.gui.renderer.quads.items()));
    try std.testing.expect(fixture.chrome.animation.wakeupAfter(started_ns) > 0);

    fixture.chrome.now_ns = started_ns + RingFades.duration_ns / 2;
    try fixture.prepare(projection);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        try attentionOpacity(fixture.session.gui.renderer.quads.items()),
        0.001,
    );
    fixture.chrome.present(false);

    fixture.chrome.now_ns = started_ns + 4 * RingFades.duration_ns;
    try std.testing.expect(fixture.chrome.animation.due(fixture.chrome.now_ns));
    try fixture.paint(projection);
    try std.testing.expectEqual(@as(f32, 1), try attentionOpacity(fixture.session.gui.renderer.quads.items()));
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
    try std.testing.expectEqual(version, fixture.session.gui.app.model.version());

    _ = fixture.session.gui.app.model.tabs.layout[tab].focusPane(second);
    projection = fixture.projection();
    projection.agents = &agents;
    try fixture.paint(projection);
    try std.testing.expectError(error.MissingAttentionRing, attentionOpacity(fixture.session.gui.renderer.quads.items()));
    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.rings.len);
    try std.testing.expectEqual(@as(u32, 0), fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns));
}

test "hiding the only animated widget removes its frame deadline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const app = &fixture.session.gui.app;
    var bytes: [4096]u8 = undefined;
    const snapshot = try core.encodeAgentSnapshot(&bytes, .{ .revision = 1, .entries = &.{.{
        .pane_id = Session.pane_id,
        .pane_generation = 1,
        // The agent lives in a tab this window does not show, so only its
        // sidebar card animates; a visible tab would keep its own spinner.
        .location = .{ .workspace = Session.location.workspace, .tab_id = @enumFromInt(77) },
        .pane_index = 1,
        .process_id = 1,
        .session_id = @splat(0),
        .provider = .codex,
        .status = .working,
        .source = .lifecycle_report,
        .authority = .active,
        .confidence = 100,
        .sequence = 1,
        .observed_at_ms = 0,
        .expires_at_ms = 1000,
    }} });
    _ = try client.runtime_messages.handleServerMessage(app, try core.decodeServer(snapshot));
    const version = app.model.version();
    try std.testing.expect(app.model.host.animation_frame_ns == null);
    try std.testing.expect(data.sidebar_animation.isActive(&app.model));
    try std.testing.expect(!app.model.sidebar_animation_scheduler.pending);
    try std.testing.expectEqual(version, app.model.version());

    fixture.chrome.now_ns = 100 * std.time.ns_per_s;
    var projection = fixture.projection();
    try fixture.paint(projection);
    try std.testing.expect(fixture.chrome.animation.wakeupAfter(fixture.chrome.now_ns) > 0);

    try fixture.showSidebar(false);
    fixture.chrome.now_ns += std.time.ns_per_s;
    projection = fixture.projection();
    try fixture.paint(projection);
    try std.testing.expect(!app.model.sidebar_animation_scheduler.pending);
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
    const pane = app.model.panes.find(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
    const version = app.model.version();
    fixture.chrome.now_ns = std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(fixture.chrome.now_ns + FrameClock.frame_interval_ns, fixture.chrome.animation.deadline_ns.?);
    const previous = try std.testing.allocator.dupe(Quad, fixture.session.gui.renderer.quads.items());
    defer std.testing.allocator.free(previous);

    fixture.chrome.now_ns += FrameClock.frame_interval_ns;
    try fixture.prepare(fixture.projection());
    const next = fixture.session.gui.renderer.quads.items();
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
    try std.testing.expect(!app.model.sidebar_animation_scheduler.pending);
}

test "native paused failed and removed progress stop their frame clock" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const pane = fixture.session.gui.app.model.panes.find(Session.pane_id).?;
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
    _ = try data.tab_creation.add(model, .{ .location = .{ .workspace = Session.location.workspace, .tab_id = second }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, model.host.host_size);
    _ = data.tab_selection.select(model, Session.location.tab_id);
    const pane = model.panes.find(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
    fixture.chrome.now_ns = std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(usize, 1), fixture.chrome.progress.len);
    try std.testing.expect(fixture.chrome.animation.deadline_ns != null);

    _ = data.tab_selection.select(model, second);
    fixture.chrome.now_ns += std.time.ns_per_s;
    try fixture.paint(fixture.projection());
    try std.testing.expectEqual(@as(usize, 0), fixture.chrome.progress.len);
    try std.testing.expectEqual(@as(?u64, null), fixture.chrome.animation.deadline_ns);
    try std.testing.expect(!fixture.chrome.animation.due(std.math.maxInt(u64)));

    _ = data.tab_selection.select(model, Session.location.tab_id);
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
