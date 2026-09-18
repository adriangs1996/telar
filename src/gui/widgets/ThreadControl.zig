const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Target = @import("interaction/Target.zig");
const Control = @This();

bounds: @import("../render/Rect.zig"),
pane_id: core.PaneId,
generation: u64,
kind: @FieldType(@import("interaction/AgentControl.zig"), "kind"),
approval_id: u64 = 0,
enabled: bool = true,
label: []const u8,

/// Registers the exact action and generation shown by the delivered button.
/// Example: `try send_button.draw(canvas);`
pub fn draw(control: Control, canvas: *Canvas) !void {
    if (control.bounds.width <= 0 or control.bounds.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const primary = control.kind == .submit or control.kind == .approve;
    try canvas.fillRoundedAt(control.bounds, .{ .color = if (control.enabled and primary) palette.accent else palette.surface1, .radius = canvas.chrome.px(6) });
    const inset = @min(canvas.chrome.px(10), control.bounds.width / 8);
    var label = control.bounds;
    label.x += inset;
    label.width -= 2 * inset;
    _ = try canvas.textAt(label, .{ .text = control.label, .face = .sans, .size = .small, .bold = true, .color = if (!control.enabled) palette.overlay1 else if (primary) palette.surface_dim else palette.text });
    if (canvas.widgets) |state| {
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = control.generation }, .bounds = control.bounds, .action = .{ .agent_control = .{ .pane_id = control.pane_id, .kind = control.kind, .approval_id = control.approval_id } }, .enabled = control.enabled }).labelled(control.label));
    }
}
