//! Composes widgets and seals interaction results; Renderer executes the list.
const data = @import("model");
const client = @import("telar-client");
const Frame = @import("Frame.zig");
const Composition = @import("../widgets/Composition.zig");
const Renderer = @import("Renderer.zig");
const Chrome = @import("../widgets/Chrome.zig");
const Overlays = @import("../widgets/overlays/Overlays.zig");
const LinkHit = @import("../input/LinkHit.zig");
const State = @import("../widgets/interaction/State.zig");
const Store = @import("../diagrams/Store.zig");
const ImagePreviews = @import("../ImagePreviews.zig");
const Scene = @This();

renderer: *Renderer,
chrome: *Chrome,
overlays: *Overlays,
theme: data.ColorTheme,
link: ?*const LinkHit = null,
widgets: ?*State = null,
diagrams: ?*Store = null,
previews: ?*const ImagePreviews = null,
/// Frame widgets the last `compose` left out because the list was full.
dropped_widgets: usize = 0,

/// Selects widgets and prepares their interaction storage without drawing.
/// The caller keeps frame at this address until rasterization has finished.
pub fn compose(self: *Scene, frame: *Frame, projection: client.Projection) !data.PresentationCommit {
    frame.* = .{
        .projection = projection,
        .theme = self.theme,
        .animation = &self.chrome.animation,
        .interaction = self.widgets,
        .diagram_store = self.diagrams,
    };
    self.chrome.animation.begin(self.chrome.now_ns);
    var canvas = self.renderer.canvas(frame);
    if (self.widgets) |widgets| {
        widgets.begin(projection.prompt != null);
        widgets.prompt_generation = if (projection.prompt) |prompt| prompt.generation else 0;
    }

    self.overlays.scale = self.renderer.scale;
    var composition: Composition = .{
        .chrome = self.chrome,
        .overlays = self.overlays,
        .canvas = &canvas,
        .context = &frame.context,
        .link = self.link,
        .previews = self.previews,
    };
    frame.widgets = try composition.render(&frame.projection);
    self.dropped_widgets = frame.widgets.dropped;
    return composition.commit;
}

/// Publishes pending hit records only after the complete widget list drew.
/// Delivery still decides whether these records replace the visible targets.
pub fn seal(self: *Scene) void {
    self.chrome.seal();
    self.overlays.seal();
    if (self.widgets) |state| {
        state.seal();
    }
}
