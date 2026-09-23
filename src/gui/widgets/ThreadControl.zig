const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Target = @import("interaction/Target.zig");
const Rect = @import("../render/Rect.zig");
const AgentControl = @import("interaction/AgentControl.zig");
const Control = @This();

bounds: Rect,
pane_id: core.PaneId,
generation: u64,
kind: @FieldType(AgentControl, "kind"),
approval_id: u64 = 0,
enabled: bool = true,
label: []const u8,

/// Registers the exact action and generation shown by the delivered button.
/// Example: `try send_button.draw(canvas);`
pub fn draw(self: Control, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    const palette = canvas.theme.palette;
    const primary = self.kind == .submit or self.kind == .approve;
    try canvas.fillRoundedAt(self.bounds, .{ .color = if (self.enabled and primary) palette.accent else palette.surface1, .radius = canvas.chrome.px(6) });
    const inset = @min(canvas.chrome.px(10), self.bounds.width / 8);
    var label = self.bounds;
    label.x += inset;
    label.width -= 2 * inset;
    _ = try canvas.textAt(label, .{ .text = self.label, .face = .sans, .size = .small, .bold = true, .color = if (!self.enabled) palette.overlay1 else if (primary) palette.surface_dim else palette.text });
    if (canvas.widgets) |state| {
        _ = try state.dispatcher.add((Target{ .id = .{ .generation = self.generation }, .bounds = self.bounds, .action = .{ .agent_control = .{ .pane_id = self.pane_id, .kind = self.kind, .approval_id = self.approval_id } }, .enabled = self.enabled }).labelled(self.label));
    }
}
