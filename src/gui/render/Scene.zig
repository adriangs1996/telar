//! Orders native layers during one synchronous semantic-model borrow.
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Scene = @This();

terminal: *@import("TerminalRenderer.zig"),
chrome: *@import("../chrome/Chrome.zig"),
overlays: *@import("../overlays/Overlays.zig"),
theme: client.ColorTheme,
link: ?*const @import("../input/LinkHit.zig") = null,

/// Nothing retained by a layer may borrow the projection after this returns.
/// Example: `const commit = try scene.prepare(projection);`
pub fn prepare(scene: *Scene, projection: client.Projection) !client.PresentationCommit {
    const renderer = scene.terminal;
    var commit = try renderer.prepare(projection);
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = scene.theme, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .sprites = if (renderer.sprites) |*page| page else null };
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
    scene.overlays.scale = renderer.scale;
    try scene.overlays.paint(&canvas, projection);
    renderer.seal();
    return commit;
}
