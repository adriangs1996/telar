const data = @import("model");
const frame_widget = @import("../widgets/frame_widget.zig");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Renderer = @import("../render/TerminalRenderer.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Overlays = @import("../widgets/overlays/Overlays.zig");
const State = @import("../widgets/interaction/State.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const PointerEvent = @import("../input/PointerEvent.zig");
const Fixture = @This();

model: data.ClientModel,
renderer: Renderer,
overlays: Overlays = .{},
widgets: State = .{},
animation: ?FrameClock = null,
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

pub fn deinit(self: *Fixture) void {
    self.renderer.deinit();
    self.model.deinit();
    std.testing.allocator.destroy(self);
}

pub fn projection(self: *Fixture) client.Projection {
    var view = client.capture(&self.model, .{ .geometry = .{ .area = .{ .w = self.size.cols, .h = self.size.rows }, .revision = 1 } });
    view.host_size = self.size;
    return view;
}

pub fn canvas(self: *Fixture) Canvas {
    return .{ .atlas = &self.renderer.atlas.?, .quads = &self.renderer.quads, .metrics = self.renderer.metrics, .origin = self.renderer.origin, .theme = data.theme_support.default_theme, .chrome = self.renderer.chrome, .viewport = self.renderer.viewport };
}

pub fn paint(self: *Fixture) !void {
    try self.prepare();
    self.present(true);
}

pub fn prepare(self: *Fixture) !void {
    self.renderer.quads.clear();
    var target = self.canvas();
    target.widgets = &self.widgets;
    target.animation = if (self.animation) |*clock| clock else null;
    self.widgets.begin(self.model.name_prompt.active());
    const projection_value = self.projection();
    self.widgets.prompt_generation = if (projection_value.prompt) |prompt| prompt.generation else 0;
    var widgets: frame_widget.List = .{};
    try self.overlays.compose(.{ .canvas = &target, .projection = &projection_value }, &widgets);
    try widgets.draw(&target);
    self.overlays.seal();
    try self.widgets.overlays(&target, &self.overlays);
    self.widgets.seal();
}

/// Example: `fixture.present(false);`
pub fn present(self: *Fixture, delivered: bool) void {
    self.overlays.present(delivered);
    self.widgets.present(delivered);
}

/// Example: `const result = fixture.pointer(.{ .kind = .press, .x = 10, .y = 20 });`
pub fn pointer(self: *Fixture, event: PointerEvent) client.ViewInteractionCommand {
    const routed = self.widgets.dispatcher.route(.{ .pointer = event });
    return .{ .consumed = routed.consumed, .intent = if (routed.target) |target| if (target.action == .intent) target.action.intent else .none else .none };
}
