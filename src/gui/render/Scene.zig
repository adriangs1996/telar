//! Composes and draws one widget list during a synchronous semantic-model borrow.
const core = @import("telar-core");
const data = @import("model");
const view_module = @import("../diagrams/view.zig");
const std = @import("std");
const Rect = @import("Rect.zig");
const Preview = @import("../widgets/interaction/ImagePreview.zig");
const Target = @import("../widgets/interaction/Target.zig");
const client = @import("telar-client");
const Canvas = @import("../widgets/Canvas.zig");
const Composition = @import("../widgets/Composition.zig");
const SyntaxStore = @import("../syntax/Store.zig");
const ReviewWidget = @import("../change_review/Widget.zig");
const TerminalRenderer = @import("TerminalRenderer.zig");
const Chrome = @import("../widgets/Chrome.zig");
const Overlays = @import("../widgets/overlays/Overlays.zig");
const LinkHit = @import("../input/LinkHit.zig");
const State = @import("../widgets/interaction/State.zig");
const Store = @import("../diagrams/Store.zig");
const Scene = @This();

terminal: *TerminalRenderer,
chrome: *Chrome,
overlays: *Overlays,
theme: data.ColorTheme,
link: ?*const LinkHit = null,
widgets: ?*State = null,
diagrams: ?*Store = null,
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

const ImagePreview = struct {
    preview: *const Preview,

    /// Paints above pane clipping only while the prepared frame retains the draft.
    /// Example: `try ImagePreview.drawCurrent(canvas);`
    pub fn drawCurrent(canvas: *Canvas) !void {
        const state = canvas.widgets orelse return;
        const preview = if (state.image_preview) |*value| value else return;
        const registry = state.dispatcher.maps.preparing();
        var found = false;
        for (registry.targets[0..registry.len]) |target| {
            if (preview.matches(target)) {
                found = true;
                break;
            }
        }

        if (!found or registry.modal_layer != 0) {
            state.image_preview = null;
            return;
        }

        registry.modal_layer = 1;
        try (ImagePreview{ .preview = preview }).draw(canvas);
    }

    /// Example: `try preview_overlay.draw(canvas);`
    pub fn draw(self: ImagePreview, canvas: *Canvas) !void {
        const preview = self.preview;
        const state = canvas.widgets orelse return;
        const window: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(canvas.viewport[0]), .height = @floatFromInt(canvas.viewport[1]) };
        const margin = @min(canvas.chrome.px(36), @min(window.width, window.height) / 12);
        const area: Rect = .{ .x = margin, .y = margin, .width = @max(0, window.width - 2 * margin), .height = @max(0, window.height - 2 * margin) };
        try canvas.dimAt(window, 0.85);
        try canvas.fillRoundedAt(area, .{ .color = canvas.theme.palette.surface_dim, .radius = canvas.chrome.px(12) });
        var close = preview.control;
        close.kind = .close_image;
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = preview.generation }, .namespace = 1, .bounds = window, .action = .{ .agent_control = close }, .layer = 1, .focusable = false }).labelled("Close image preview"));
        _ = try state.dispatcher.add(.{ .id = .{ .generation = preview.generation }, .namespace = 2, .bounds = area, .action = .{ .custom = 0 }, .layer = 1, .focusable = false });
        const header = @min(canvas.chrome.px(40), area.height / 5);
        const content: Rect = .{ .x = area.x + margin / 2, .y = area.y + header, .width = @max(0, area.width - margin), .height = @max(0, area.height - header - margin / 2) };
        const request = Preview.requestFor(.{ .pane_id = preview.control.pane_id, .generation = preview.generation, .path = preview.path() });
        const view: view_module.View = if (canvas.diagrams) |store| store.request(request) else .{ .failed = .unavailable };
        switch (view) {
            .ready => |ready| try canvas.diagramAt(Preview.fit(content, .{ ready.width, ready.height }), ready.slot),
            else => _ = try canvas.textAt(content, .{ .text = if (view == .pending) "Loading image…" else "Image preview unavailable", .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 }),
        }

        var storage: [32]u8 = undefined;
        _ = try canvas.textAt(.{ .x = content.x, .y = area.y, .width = @max(0, content.width - header), .height = header }, .{ .text = try std.fmt.bufPrint(&storage, "Image {d}", .{preview.control.image_index + 1}), .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 });
        const button: Rect = .{ .x = area.x + area.width - header, .y = area.y, .width = header, .height = header };
        try canvas.iconAt(button, .{ .text = "\u{f00d}", .size = .body, .color = canvas.theme.palette.text });
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = preview.generation }, .bounds = button, .action = .{ .agent_control = close }, .layer = 1 }).labelled("Close image preview"));
    }
};
