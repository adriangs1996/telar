const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Renderer = @import("../render/TerminalRenderer.zig");
const Canvas = @import("../chrome/Canvas.zig");
const Overlays = @import("../overlays/Overlays.zig");
const Fixture = @This();

model: client.Model,
renderer: Renderer,
overlays: Overlays = .{},
widgets: @import("../widgets/interaction/State.zig") = .{},
animation: ?@import("../animation/FrameClock.zig") = null,
size: core.TerminalSize,

pub fn init() !*Fixture {
    const fixture = try std.testing.allocator.create(Fixture);
    errdefer std.testing.allocator.destroy(fixture);
    fixture.* = .{ .model = .init(std.testing.allocator, true), .renderer = .init(std.testing.allocator), .size = undefined };
    errdefer fixture.model.deinit();
    errdefer fixture.renderer.deinit();
    fixture.size = try fixture.renderer.measure(.{ .width = 1280, .height = 720, .scale = 1 });
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.renderer.deinit();
    fixture.model.deinit();
    std.testing.allocator.destroy(fixture);
}

pub fn projection(fixture: *Fixture) client.Projection {
    var view = client.capture(&fixture.model, .{ .geometry = .{ .area = .{ .w = fixture.size.cols, .h = fixture.size.rows }, .revision = 1 } });
    view.host_size = fixture.size;
    return view;
}

pub fn canvas(fixture: *Fixture) Canvas {
    return .{ .atlas = &fixture.renderer.atlas.?, .quads = &fixture.renderer.quads, .metrics = fixture.renderer.metrics, .origin = fixture.renderer.origin, .theme = client.theme_support.default_theme, .chrome = fixture.renderer.chrome, .viewport = fixture.renderer.viewport };
}

pub fn paint(fixture: *Fixture) !void {
    try fixture.prepare();
    fixture.present(true);
}

pub fn prepare(fixture: *Fixture) !void {
    fixture.renderer.quads.clear();
    var target = fixture.canvas();
    target.animation = if (fixture.animation) |*clock| clock else null;
    fixture.widgets.begin(fixture.model.name_prompt.active());
    try fixture.overlays.paint(&target, fixture.projection());
    try fixture.widgets.overlays(&target, &fixture.overlays);
    fixture.widgets.seal();
}

/// Example: `fixture.present(false);`
pub fn present(fixture: *Fixture, delivered: bool) void {
    fixture.overlays.present(delivered);
    fixture.widgets.present(delivered);
}

/// Example: `const result = fixture.pointer(.{ .kind = .press, .x = 10, .y = 20 });`
pub fn pointer(fixture: *Fixture, event: @import("../input/PointerEvent.zig")) client.ViewInteractionCommand {
    const routed = fixture.widgets.dispatcher.route(.{ .pointer = event });
    return .{ .consumed = routed.consumed, .intent = if (routed.target) |target| if (target.action == .intent) target.action.intent else .none else .none };
}
