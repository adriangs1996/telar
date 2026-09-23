//! Composes and draws one widget list during a synchronous semantic-model borrow.
const core = @import("telar-core");
const data = @import("model");
const ImagePreview = @import("../widgets/overlays/ImagePreview.zig");
const client = @import("telar-client");
const Canvas = @import("../widgets/Canvas.zig");
const Composition = @import("../widgets/Composition.zig");
const SyntaxStore = @import("../syntax/Store.zig");
const ReviewWidget = @import("../change_review/Widget.zig");
const Scene = @This();

terminal: *@import("TerminalRenderer.zig"),
chrome: *@import("../widgets/Chrome.zig"),
overlays: *@import("../widgets/overlays/Overlays.zig"),
theme: data.ColorTheme,
link: ?*const @import("../input/LinkHit.zig") = null,
widgets: ?*@import("../widgets/interaction/State.zig") = null,
diagrams: ?*@import("../diagrams/Store.zig") = null,
syntax: ?*SyntaxStore = null,
review: ?*ReviewWidget = null,

/// Nothing retained by a layer may borrow the projection after this returns.
/// Example: `const commit = try scene.prepare(projection);`
pub fn prepare(self: *Scene, projection: client.Projection) !data.PresentationCommit {
    core.profiling.add(.gui_scene, 1);
    const profile_started = if (self.terminal.io) |io| core.profiling.start(io) else 0;
    defer {
        if (self.terminal.io) |io| {
            core.profiling.finish(io, .gui_scene, profile_started);
        }
    }
    const renderer = self.terminal;
    renderer.begin();
    self.chrome.animation.begin(self.chrome.now_ns);
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &renderer.quads, .metrics = renderer.metrics, .origin = renderer.origin, .theme = self.theme, .background_opacity = renderer.config.window.background_opacity, .chrome = renderer.chrome, .viewport = renderer.viewport, .sidebar = renderer.sidebar, .sprites = if (renderer.sprites) |*page| page else null, .terminal_renderer = renderer };
    canvas.animation = &self.chrome.animation;
    canvas.widgets = self.widgets;
    canvas.diagrams = self.diagrams;
    canvas.syntax = self.syntax;
    if (self.widgets) |widgets| {
        widgets.begin(projection.prompt != null);
        widgets.prompt_generation = if (projection.prompt) |prompt| prompt.generation else 0;
    }
    self.overlays.scale = renderer.scale;
    var composition: Composition = .{ .chrome = self.chrome, .overlays = self.overlays, .canvas = &canvas, .link = self.link };
    const widgets = try composition.render(&projection);
    try widgets.draw(&canvas);

    if (self.review) |review| {
        if (self.widgets) |state| {
            state.begin(true);
        }
        try review.draw(&canvas);
    } else if (self.widgets) |state| {
        try state.overlays(&canvas, self.overlays);
        try ImagePreview.drawCurrent(&canvas);
        if (state.message_link_preview) |*preview| {
            try preview.draw(&canvas);
        }
    }

    if (self.widgets) |state| {
        try state.copy_feedback.draw(&canvas);
    }

    self.chrome.seal();
    self.overlays.seal();
    if (self.widgets) |state| {
        state.seal();
    }
    renderer.seal();
    return composition.commit;
}
