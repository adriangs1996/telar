//! Composes and draws one widget list during a synchronous semantic-model borrow.
const client = @import("telar-client");
const Canvas = @import("../chrome/Canvas.zig");
const Composition = @import("../widgets/Composition.zig");
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
    renderer.begin();
    scene.chrome.animation.begin(scene.chrome.now_ns);
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = scene.theme, .background_opacity = renderer.config.window.background_opacity, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .sprites = if (renderer.sprites) |*page| page else null, .terminal_renderer = renderer };
    canvas.animation = &scene.chrome.animation;
    canvas.widgets = scene.widgets;
    if (scene.widgets) |widgets| {
        widgets.begin(projection.prompt != null);
        widgets.prompt_generation = if (projection.prompt) |prompt| prompt.generation else 0;
    }
    scene.overlays.scale = renderer.scale;
    var composition: Composition = .{ .chrome = scene.chrome, .overlays = scene.overlays, .canvas = &canvas, .link = scene.link };
    const widgets = try composition.render(&projection);
    try widgets.draw(&canvas);

    if (scene.widgets) |state| {
        try state.overlays(&canvas, scene.overlays);
    }

    scene.chrome.seal();
    scene.overlays.seal();
    if (scene.widgets) |state| {
        state.seal();
    }
    renderer.seal();
    return composition.commit;
}
