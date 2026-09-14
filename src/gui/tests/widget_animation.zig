const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const RingFades = @import("../chrome/RingFades.zig");
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
