//! The fullscreen pane's bottom band. The focused pane keeps its header
//! entry (application mark, index in bold, name, status chip) and the tab's
//! hidden panes follow in display order with the tab strip's label
//! composition (mark, index, name) but no tab surface, dimmed the way an
//! unfocused pane is. A hidden agent that needs the person keeps its
//! attention dot. The right end holds the progress capsule, the change-review
//! button and the control that leaves fullscreen. Hidden names give way to
//! marks before the row scrolls around the focused pane, so the focused entry
//! stays visible at any width.
const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const Context = @import("Context.zig");
const action_module = @import("action.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const attention = @import("attention.zig");
const application_mark = @import("application_mark.zig");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const PaneProgress = @import("PaneProgress.zig");
const ChangeReviewButton = @import("ChangeReviewButton.zig");
const StatusChip = @import("StatusChip.zig");
const AttentionDot = @import("AttentionDot.zig");
const PixelButton = @import("PixelButton.zig");
const TabStrip = @import("TabStrip.zig");
const FullscreenStrip = @This();

context: *const Context,
tab: usize,
area: Rect,

/// Logical pixels between two pane entries.
const entry_gap: f32 = 16;
/// Logical pixels between the parts of one entry.
const part_gap: f32 = 6;
/// Logical pixels between the focused name and its status chip.
const chip_gap: f32 = 8;
/// Logical width of the leave-fullscreen control.
const leave_width: f32 = 22;
/// Logical inset of the band inside the border row.
const margin: f32 = 8;
/// Logical room the focused entry keeps beside a progress capsule.
const min_entry_room: f32 = 48;
const mark_label: Label = .{ .text = "", .face = .sans, .size = .body };

const Entry = struct {
    id: core.PaneId,
    index: u16,
    name: []const u8,
    icon: data.icons.Icon,
    focused: bool,
    dot: ?cellgrid.Color,
};

/// Paints into the pixel rectangle of the bottom border row.
/// Example: `try strip.draw(canvas);`
pub fn draw(self: FullscreenStrip, canvas: *Canvas) !void {
    const chrome = canvas.chrome;
    const row = self.area;
    const band_height = @min(row.height, @as(f32, @floatFromInt(chrome.pane_header)));
    if (band_height <= 0 or row.width <= 0) {
        return;
    }

    const projection = self.context.projection;
    const model = projection.model;
    const location = model.tabs.location[self.tab];
    const layout = &model.tabs.layout[self.tab];
    const focused_id = layout.focused() orelse return;
    var band: Rect = .{ .x = row.x + chrome.px(margin), .y = row.y + @floor((row.height - band_height) / 2), .width = @max(0, row.width - 2 * chrome.px(margin)), .height = band_height };
    band.width = @max(0, band.width - try self.leaveControl(canvas, band));
    if (model.panes.findInConst(location.tab_id, focused_id)) |pane| {
        band.width = @max(0, band.width - try (ChangeReviewButton{ .area = band, .pane = pane, .placement = .fullscreen }).draw(canvas));
        band.width = @max(0, band.width - try self.progress(canvas, band, pane));
    }

    var identities: [core.max_panes_per_tab]core.PaneId = undefined;
    const panes = layout.orderedPanes(&identities);
    if (panes.len == 0) {
        return;
    }

    var entries: [core.max_panes_per_tab]Entry = undefined;
    var focused_index: usize = 0;
    for (panes, 0..) |id, index| {
        entries[index] = self.entry(canvas, location, id, @intCast(index + 1));
        if (id == focused_id) {
            focused_index = index;
        }
    }

    const chip: StatusChip = .{ .context = self.context, .agent = attention.paneAgent(projection, location, focused_id), .area = band };
    const chip_width = try chip.width(canvas);
    const gap = chrome.px(entry_gap);
    var widths: [core.max_panes_per_tab]f32 = undefined;
    var total = gap * @as(f32, @floatFromInt(panes.len - 1));
    for (entries[0..panes.len], 0..) |*item, index| {
        widths[index] = try entryWidth(canvas, item, true, chip_width);
        total += widths[index];
    }

    const named = total <= band.width;
    if (!named) {
        for (entries[0..panes.len], 0..) |*item, index| {
            widths[index] = try entryWidth(canvas, item, false, chip_width);
        }
    }

    const first = TabStrip.firstVisible(focused_index, widths[0..panes.len], .{ .available = band.width, .gap = gap });
    var x = band.x;
    const end = band.x + band.width;
    for (entries[first..panes.len], first..) |*item, index| {
        if (index != first) {
            x += gap;
        }

        const width = @min(widths[index], @max(0, end - x));
        if (width <= 0) {
            break;
        }

        const bounds: Rect = .{ .x = x, .y = band.y, .width = width, .height = band.height };
        const advance = try self.paintEntry(canvas, item, bounds, named);
        if (item.focused and chip_width > 0) {
            const chip_x = @min(end, x + advance + chrome.px(chip_gap));
            var placed = chip;
            placed.area = .{ .x = chip_x, .y = band.y, .width = @max(0, @min(chip_width, x + width - chip_x)), .height = band.height };
            try placed.draw(canvas);
        }

        x += width;
    }
}

fn entry(self: FullscreenStrip, canvas: *const Canvas, location: core.TabLocation, id: core.PaneId, index: u16) Entry {
    const projection = self.context.projection;
    const model = projection.model;
    const focused = model.tabs.layout[self.tab].focused() == id;
    const foreground = if (model.panes.findInConst(location.tab_id, id)) |pane| pane.foregroundName() else "";
    const name = if (foreground.len == 0) "shell" else foreground;
    return .{
        .id = id,
        .index = index,
        .name = name,
        .icon = data.icons.Icon.forApplication(name),
        .focused = focused,
        .dot = if (focused) null else attention.paneDot(projection, canvas.theme.palette, location, id),
    };
}

// Only warm labels are measured here, so a repaint reads the shaping cache.
fn entryWidth(canvas: *Canvas, item: *const Entry, named: bool, chip_width: f32) !f32 {
    const chrome = canvas.chrome;
    var storage: [8]u8 = undefined;
    var width = canvas.iconSize(mark_label) + chrome.px(part_gap) + try canvas.measure(indexLabel(item, &storage, .default));
    if (named or item.focused) {
        width += chrome.px(part_gap) + try canvas.measure(nameLabel(item, .default));
    }

    if (item.dot != null) {
        width += chrome.px(AttentionDot.gap + AttentionDot.diameter);
    }

    if (item.focused and chip_width > 0) {
        width += chrome.px(chip_gap) + chip_width;
    }

    return width;
}

// Paints one entry left to right inside `bounds` and returns its painted
// advance; a hidden entry also becomes a focus target.
fn paintEntry(self: FullscreenStrip, canvas: *Canvas, item: *const Entry, bounds: Rect, named: bool) !f32 {
    const palette = canvas.theme.palette;
    const chrome = canvas.chrome;
    const action: action_module.Action = .{ .intent = .{ .focus_pane = item.id } };
    const hovered = !item.focused and self.context.isHovered(action);
    const ink = if (item.focused or hovered) palette.text else palette.overlay1;
    const side = canvas.iconSize(mark_label);
    const end = bounds.x + bounds.width;
    var x = bounds.x;
    const mark: Rect = .{ .x = x, .y = bounds.y + (bounds.height - side) / 2, .width = @max(0, @min(side, end - x)), .height = side };
    if (mark.width > 0) {
        try application_mark.draw(canvas, item.icon, mark, !item.focused and !hovered);
    }

    x += side + chrome.px(part_gap);
    var storage: [8]u8 = undefined;
    x += try canvas.textAt(.{ .x = x, .y = bounds.y, .width = @max(0, end - x), .height = bounds.height }, indexLabel(item, &storage, ink));
    if (named or item.focused) {
        x += chrome.px(part_gap);
        x += try canvas.textAt(.{ .x = x, .y = bounds.y, .width = @max(0, end - x), .height = bounds.height }, nameLabel(item, if (item.focused) palette.subtext0 else ink));
    }

    if (item.dot) |color| {
        const dot_width = chrome.px(2 * AttentionDot.gap + AttentionDot.diameter);
        if (x + dot_width <= end) {
            const dot: AttentionDot = .{ .area = .{ .x = x, .y = bounds.y, .width = dot_width, .height = bounds.height }, .color = color };
            try dot.draw(canvas);
        }

        x += chrome.px(AttentionDot.gap + AttentionDot.diameter);
    }

    if (!item.focused) {
        self.context.bands.add(.{
            .area = bounds,
            .action = action,
        });
    }

    return @min(x, end) - bounds.x;
}

fn leaveControl(self: FullscreenStrip, canvas: *Canvas, band: Rect) !f32 {
    const width = @min(band.width, canvas.chrome.px(leave_width));
    if (width <= 0) {
        return 0;
    }

    const button: PixelButton = .{
        .context = self.context,
        .area = .{ .x = band.x + band.width - width, .y = band.y, .width = width, .height = band.height },
        .intent = .toggle_pane_fullscreen,
        .text = data.icons.Icon.pane_fullscreen.unicodeGlyph(),
        .background = false,
        .alignment = .center,
    };
    try button.draw(canvas);
    return width + canvas.chrome.px(part_gap);
}

fn progress(self: FullscreenStrip, canvas: *Canvas, band: Rect, pane: *const data.Pane) !f32 {
    var capsule: PaneProgress = .{ .pane = pane, .area = band, .motions = self.context.progress };
    if (try capsule.width(canvas) > band.width / 2) {
        capsule.compact = true;
    }

    const width = try capsule.width(canvas);
    if (width <= 0 or width + canvas.chrome.px(part_gap + min_entry_room) > band.width) {
        return 0;
    }

    try capsule.draw(canvas);
    return width + canvas.chrome.px(part_gap);
}

fn indexLabel(item: *const Entry, storage: *[8]u8, color: cellgrid.Color) Label {
    return .{
        .text = std.fmt.bufPrint(storage, "{d}", .{item.index}) catch unreachable,
        .color = color,
        .bold = item.focused,
        .face = .sans,
        .size = .body,
    };
}

fn nameLabel(item: *const Entry, color: cellgrid.Color) Label {
    return .{ .text = item.name, .color = color, .face = .sans, .size = .body };
}
