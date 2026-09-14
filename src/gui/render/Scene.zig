//! Orders native layers during one synchronous semantic-model borrow.
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Scene = @This();

terminal: *@import("TerminalRenderer.zig"),
chrome: *@import("../chrome/Chrome.zig"),
overlays: *@import("../overlays/Overlays.zig"),
theme: client.ColorTheme,
link: ?*const @import("../input/LinkHit.zig") = null,
widgets: ?*@import("../widgets/interaction/State.zig") = null,

/// Nothing retained by a layer may borrow the projection after this returns.
/// Example: `const commit = try scene.prepare(projection);`
pub fn prepare(scene: *Scene, projection: client.Projection) !client.PresentationCommit {
    const renderer = scene.terminal;
    var commit = try renderer.prepare(projection);
    scene.chrome.animation.begin(scene.chrome.now_ns);
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = scene.theme, .background_opacity = renderer.config.window.background_opacity, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .sprites = if (renderer.sprites) |*page| page else null };
    canvas.animation = &scene.chrome.animation;
    canvas.widgets = scene.widgets;
    if (scene.widgets) |widgets| {
        widgets.begin(projection.prompt != null);
        widgets.prompt_generation = if (projection.prompt) |prompt| prompt.generation else 0;
    }
    if (projection.model) |model| {
        var layout: client.LayoutSnapshot = .{};
        model.layout.snapshot(projection.geometry.area, &layout);
        for (layout.views()) |view| {
            if (view.surface == .terminal) {
                continue;
            }

            if (projection.threadView(view.pane_id)) |thread| {
                try @import("../overlays/thread.zig").paint(&canvas, view.content, thread);
                if (model.findConst(view.pane_id)) |pane| {
                    commit.append(pane);
                }
            }
        }
    }

    if (scene.link) |hit| {
        if (projection.model) |model| {
            if (model.findConst(hit.pane_id)) |pane| {
                if (pane.attachment_generation == hit.generation) {
                    try @import("link_decoration.zig").paint(&canvas, hit, pane);
                }
            }
        }
    }

    try scene.chrome.paint(&canvas, projection);
    if (scene.widgets) |widgets| {
        try widgets.chrome(&canvas, .{ .chrome = scene.chrome, .projection = &projection });
    }
    scene.overlays.scale = renderer.scale;
    try scene.overlays.paint(&canvas, projection);
    if (scene.widgets) |widgets| {
        try widgets.overlays(&canvas, scene.overlays);
        widgets.seal();
    }
    renderer.seal();
    return commit;
}
