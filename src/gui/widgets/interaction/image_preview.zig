const core = @import("telar-core");
const event_module = @import("../../input/event.zig");
const GuiAdapter = @import("../../GuiAdapter.zig");
const Target = @import("Target.zig");
const ImagePreview = @import("ImagePreview.zig");

/// Revalidates a delivered image control before copying its local reference.
/// Example: `image_preview.open(gui, target);`
pub fn open(gui: *GuiAdapter, target: Target) void {
    const control = target.action.agent_control;
    const pane = gui.app.model.agentPane(control.pane_id) orelse return;
    const images = pane.composerImages();
    if (pane.attachment_generation != target.id.generation or pane.composer_revision != control.composer_revision or control.image_index >= images.count) {
        return;
    }

    const path = images.path(control.image_index);
    var preview: ImagePreview = .{ .control = control, .generation = target.id.generation, .path_len = @intCast(path.len) };
    @memcpy(preview.path_storage[0..path.len], path);
    gui.widgets.cancelComposition();
    gui.widgets.image_preview = preview;
    gui.widgets.composer_menu.selector = null;
    gui.widgets.completions.open = false;
    gui.widgets.dispatcher.cancel();
    gui.widgets.dispatcher.revision +%= 1;
}

/// Example: `image_preview.close(gui);`
pub fn close(gui: *GuiAdapter) void {
    const preview = gui.widgets.image_preview orelse return;
    gui.widgets.image_preview = null;
    gui.widgets.dispatcher.revision +%= 1;
    const registry = gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer and target.action.composer == preview.control.pane_id and target.id.generation == preview.generation) {
            _ = gui.widgets.dispatcher.focus(target.id);
            break;
        }
    }
}

/// Consumes preview input even before its first frame lands or while it closes.
/// Example: `if (image_preview.route(gui, event)) return true;`
pub fn route(gui: *GuiAdapter, event: event_module.Event) bool {
    const preview = gui.widgets.image_preview orelse return false;
    const focused_pane: ?core.PaneId = if (gui.app.model.tabs.activeSlot()) |tab| gui.app.model.tabs.layout[tab].focused() else null;
    const pane = gui.app.model.agentPane(preview.control.pane_id);
    if (pane == null or focused_pane != preview.control.pane_id or pane.?.attachment_generation != preview.generation or pane.?.composer_revision != preview.control.composer_revision or gui.app.model.name_prompt.currentConst() != null) {
        close(gui);
        return false;
    }

    switch (event) {
        .focus, .clipboard => return false,
        .key => |key| {
            const result = gui.widgets.dispatcher.route(event);
            if (key.phase == .press and key.code == .escape) {
                close(gui);
            } else if (key.phase == .press and (key.code == .enter or (key.code == .char and key.code.char.len == 1 and key.code.char.bytes[0] == ' '))) {
                if (result.target) |target| {
                    if (target.layer == 1 and target.action == .agent_control and target.action.agent_control.kind == .close_image) {
                        close(gui);
                    }
                }
            }
        },
        .pointer => {
            if (event.pointer.kind == .press and !gui.pointerGeometryMatches()) {
                gui.widgets.dispatcher.discardPointer(event.pointer.button);
                return true;
            }

            const result = gui.widgets.dispatcher.route(event);
            if (event.pointer.kind == .release and event.pointer.button == .left) {
                if (result.target) |target| {
                    if (target.layer == 1 and target.action == .agent_control and target.action.agent_control.kind == .close_image and target.contains(.{ event.pointer.x, event.pointer.y })) {
                        close(gui);
                    }
                }
            }
        },
        .accessibility => |action| {
            const target = gui.widgets.dispatcher.maps.presented().find(.{ .target_id = action.target_id, .generation = action.generation }) orelse return true;
            if (action.action == .press and target.layer == 1 and target.action == .agent_control and target.action.agent_control.kind == .close_image) {
                close(gui);
            }
        },
        else => {},
    }

    return true;
}
