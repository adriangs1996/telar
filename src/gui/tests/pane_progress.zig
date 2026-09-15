const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("ChromeFixture.zig");
const Session = @import("Session.zig");
const Canvas = @import("../widgets/Canvas.zig");
const PaneProgress = @import("../widgets/PaneProgress.zig");
const ProgressMotions = @import("../widgets/ProgressMotions.zig");
const FrameClock = @import("../animation/FrameClock.zig");
const Rect = @import("../render/Rect.zig");
const Quad = @import("../render/Quad.zig").Quad;

test "native progress capsules retain labels and stay inside narrow and high DPI bounds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try fixture.measure(.{ .width = 1200, .height = 800, .scale = scale });
        const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
        var canvas = fixtureCanvas(&fixture);
        var clock: FrameClock = .{};
        canvas.animation = &clock;
        for ([_]core.PaneProgressState{ .set, .pause, .@"error", .indeterminate, .remove }) |state| {
            _ = pane.setProgress(.{ .pane_id = pane.id, .state = state, .percent = 42 });
            for ([_][2]f32{ .{ 260, 48 }, .{ 30, 20 }, .{ 9, 20 }, .{ 1, 1 }, .{ 0, 20 }, .{ 120, 0 } }) |size| {
                const bounds: Rect = .{ .x = 17.5, .y = 31.25, .width = size[0] * scale, .height = size[1] * scale };
                for ([_]bool{ false, true }) |compact| {
                    var motions: ProgressMotions = .{};
                    const progress: PaneProgress = .{ .pane = pane, .area = bounds, .compact = compact, .motions = &motions };
                    canvas.quads.clear();
                    clock.begin(750 * std.time.ns_per_ms);
                    motions.begin();
                    try progress.draw(&canvas);
                    motions.end();
                    try expectInside(canvas.quads.items(), bounds);
                    if (state == .remove or bounds.width == 0 or bounds.height == 0) {
                        try std.testing.expectEqual(@as(usize, 0), canvas.quads.items().len);
                        try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
                    } else if (size[0] == 260) {
                        try std.testing.expect(canvas.quads.items().len > 1);
                        try std.testing.expect(canvas.quads.items()[0].radius > 0);
                        try std.testing.expectEqual(!compact, hasText(canvas.quads.items()));
                    }
                }
            }
        }
    }
}

test "warm native indeterminate progress animates without allocations shaping or atlas changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    _ = pane.setProgress(.{ .pane_id = pane.id, .state = .indeterminate });
    var canvas = fixtureCanvas(&fixture);
    var clock: FrameClock = .{};
    canvas.animation = &clock;
    var motions: ProgressMotions = .{};
    const progress: PaneProgress = .{ .pane = pane, .area = .{ .x = 8, .y = 12, .width = 260, .height = 40 }, .motions = &motions };
    for (0..90) |frame| {
        canvas.quads.clear();
        clock.begin(frame * FrameClock.frame_interval_ns);
        motions.begin();
        try progress.draw(&canvas);
        motions.end();
    }

    const atlas = canvas.atlas;
    const shape_calls = atlas.shape_calls;
    const raster_attempts = atlas.raster_attempts;
    const version = atlas.version;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const atlas_allocator = atlas.allocator;
    atlas.allocator = failing.allocator();
    defer atlas.allocator = atlas_allocator;
    const quad_allocator = canvas.quads.allocator;
    canvas.quads.allocator = failing.allocator();
    defer canvas.quads.allocator = quad_allocator;
    for (90..210) |frame| {
        canvas.quads.clear();
        clock.begin(frame * FrameClock.frame_interval_ns);
        motions.begin();
        try progress.draw(&canvas);
        motions.end();
        try expectInside(canvas.quads.items(), progress.area);
        try std.testing.expectEqual(clock.now_ns + FrameClock.frame_interval_ns, clock.deadline_ns.?);
    }

    try std.testing.expectEqual(shape_calls, atlas.shape_calls);
    try std.testing.expectEqual(raster_attempts, atlas.raster_attempts);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "native fullscreen progress leaves the focused pane selector reachable at one to three columns" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.showSidebar(false);
    const model = fixture.session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = fixture.projection().geometry.area });
    _ = model.find(Session.pane_id).?.setProgress(.{ .pane_id = Session.pane_id, .state = .indeterminate });
    _ = model.layout.focusPane(Session.pane_id);
    _ = model.layout.toggleFullscreen();
    for ([_]u16{ 1, 2, 3 }) |columns| {
        try fixture.resize(columns, 8);
        fixture.chrome.now_ns += std.time.ns_per_s;
        try fixture.paint(fixture.projection());
        try std.testing.expect(fixture.target(.{ .focus_pane = Session.pane_id }) != null);
        try std.testing.expectEqual(@as(usize, 0), fixture.chrome.progress.len);
        try std.testing.expectEqual(@as(?u64, null), fixture.chrome.animation.deadline_ns);
    }
}

fn fixtureCanvas(fixture: *Fixture) Canvas {
    const renderer = &fixture.session.renderer;
    return .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = fixture.session.gui.theme, .chrome = renderer.chrome, .viewport = renderer.viewport };
}

fn expectInside(quads: []const Quad, bounds: Rect) !void {
    for (quads) |quad| {
        try std.testing.expect(std.math.isFinite(quad.x) and std.math.isFinite(quad.y));
        try std.testing.expect(std.math.isFinite(quad.width) and std.math.isFinite(quad.height));
        try std.testing.expect(quad.width >= 0 and quad.height >= 0);
        try std.testing.expect(quad.x >= bounds.x - 0.001 and quad.y >= bounds.y - 0.001);
        try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width + 0.001);
        try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height + 0.001);
        try std.testing.expect(quad.a >= 0 and quad.a <= 1);
    }
}

fn hasText(quads: []const Quad) bool {
    for (quads) |quad| {
        if (quad.u0 != quad.u1 and quad.v0 != quad.v1) {
            return true;
        }
    }

    return false;
}
