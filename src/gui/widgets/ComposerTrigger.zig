const Canvas = @import("Canvas.zig");
const Target = @import("interaction/Target.zig");
const Selector = @import("interaction/ComposerSelector.zig");
const Trigger = @This();

bounds: @import("../render/Rect.zig"),
selector: Selector,
generation: u64,
label: []const u8,
enabled: bool,

/// Registers the exact catalog and option revision represented by this label.
/// Example: `try trigger.draw(canvas);`
pub fn draw(trigger: Trigger, canvas: *Canvas) !void {
    const palette = canvas.theme.palette;
    const name = switch (trigger.selector.kind) {
        .model => "Choose model",
        .effort => "Choose reasoning effort",
        .access => "Choose permissions",
        .recent => "Resume conversation",
    };
    const target: Target = (Target{ .id = .{ .generation = trigger.generation }, .bounds = trigger.bounds, .action = .{ .composer_selector = trigger.selector }, .enabled = trigger.enabled }).labelled(name);
    var active = false;
    if (canvas.widgets) |state| {
        const id = try state.dispatcher.add(target);
        const hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
        const focused = if (state.dispatcher.focused) |focus| focus.eql(id) else false;
        active = if (state.composer_menu.selector) |selector| @import("std").meta.eql(selector, trigger.selector) else false;
        if (hovered or active or focused) {
            try canvas.fillRoundedAt(trigger.bounds, .{ .color = palette.surface1, .radius = canvas.chrome.px(8) });
        }
    }

    const icon_width = @min(canvas.chrome.px(22), trigger.bounds.width / 5);
    const inset = canvas.chrome.px(4);
    var text_bounds = trigger.bounds;
    text_bounds.x += inset;
    text_bounds.width = @max(0, text_bounds.width - 2 * inset - icon_width);
    const tint = if (trigger.enabled) palette.text else palette.overlay1;
    if (trigger.selector.kind == .model or trigger.selector.kind == .access) {
        const icon = @import("../render/Rect.zig"){ .x = text_bounds.x, .y = text_bounds.y, .width = icon_width, .height = text_bounds.height };
        if (trigger.selector.kind == .model and canvas.providerMark(.codex) != null) {
            const mark = @min(canvas.chrome.px(17), icon_width);
            try canvas.spriteTintedAt(.{ .x = icon.x, .y = icon.y + (icon.height - mark) / 2, .width = mark, .height = mark }, .{ .sprite = canvas.providerMark(.codex).?, .color = tint });
        } else {
            try canvas.iconAt(icon, .{ .text = if (trigger.selector.kind == .model) "\u{f2db}" else "\u{f023}", .color = tint, .size = .small });
        }

        text_bounds.x += icon_width + inset;
        text_bounds.width = @max(0, text_bounds.width - icon_width - inset);
    }

    var storage: [@import("TextFit.zig").max_bytes]u8 = undefined;
    var label: @import("Label.zig") = .{ .text = trigger.label, .face = .sans, .size = .body, .color = tint };
    label.text = try (@import("TextFit.zig"){ .canvas = canvas, .width = text_bounds.width }).fit(label, &storage);
    const width = try canvas.textAt(text_bounds, label);
    const chevron_x = @min(text_bounds.x + width + inset, trigger.bounds.x + trigger.bounds.width - icon_width);
    try canvas.iconAt(.{ .x = chevron_x, .y = trigger.bounds.y, .width = icon_width, .height = trigger.bounds.height }, .{ .text = if (active) "\u{f077}" else "\u{f078}", .color = if (trigger.enabled) palette.subtext0 else palette.overlay1, .size = .small });
}
