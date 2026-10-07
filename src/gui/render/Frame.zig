//! A composed widget list, before glyph rasterization or quad generation.
//! Scene.compose fills this value in stable storage. Its widgets borrow the
//! projection, context and pending hit maps until Renderer.rasterize returns.
//! Do not update the model or move this value between composition and drawing.
const client = @import("telar-client");
const data = @import("model");
const gfx = @import("gfx");
const animate = @import("animate");
const frame_widget = @import("../widgets/frame_widget.zig");
const Context = @import("../widgets/Context.zig");
const State = @import("../widgets/interaction/State.zig");
const Store = @import("../diagrams/Store.zig");
const ImagePlacement = @import("../image/ImagePlacement.zig");

token: u64 = 0,
widgets: frame_widget.List = .{},
// SAFETY: Scene.compose initializes both before any widget borrows them.
projection: client.Projection = undefined,
// SAFETY: Composition.render assigns context before appending widgets that borrow it.
context: Context = undefined,
theme: data.ColorTheme = data.theme_support.default_theme,
animation: ?*animate.FrameClock = null,
interaction: ?*State = null,
diagram_store: ?*Store = null,
images: []const ImagePlacement = &.{},
diagrams: [gfx.Quad.diagram_slot_count]gfx.DiagramTexture.DiagramTexture = @splat(.{}),
image_uploads: []const gfx.ImageUpload.ImageUpload = &.{},
image_releases: []const u32 = &.{},
background: [4]f32 = .{ 0, 0, 0, 1 },
background_blur: u32 = 0,
titlebar: u32 = 1,
navigation: u32 = 0,
