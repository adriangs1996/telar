//! Ordered tab navigation.

const std = @import("std");
const core = @import("telar-core");
const workspace = @import("../workspace/root.zig");
const multiplexer = workspace.multiplexer;
const tabs_mod = workspace.tabs;
const widget = @import("context.zig");
const ui = @import("../ui/root.zig");

const schema = core.schema;

pub const Input = struct {
    area: ui.Rect,
    tabs: ?*const tabs_mod.Model,
    model: *const multiplexer.Model,
};

pub fn render(context: *widget.Context, input: Input) void {
    if (input.tabs) |collection| {
        if (collection.count == 0) return;
        var first_visible = collection.active_index;
        var used = displayWidth(
            collection.items[first_visible].?.labelSlice(),
            first_visible,
            input.area.w,
        );
        while (first_visible > 0) {
            const candidate = first_visible - 1;
            const width = displayWidth(
                collection.items[candidate].?.labelSlice(),
                candidate,
                input.area.w,
            );
            if (width > input.area.w -| used) break;
            first_visible = candidate;
            used += width;
        }
        // The block anchors to the right edge: when the tabs do not fill the
        // region the gap stays on the left, next to the status.
        var total: u16 = 0;
        for (collection.items[first_visible..collection.count], first_visible..) |slot, index| {
            const width = displayWidth(slot.?.labelSlice(), index, input.area.w);
            total += @min(width, input.area.w -| total);
            if (total == input.area.w) break;
        }
        var x = input.area.x + input.area.w - total;
        for (collection.items[first_visible..collection.count], first_visible..) |slot, index| {
            const tab = slot.?;
            var tab_buffer: [schema.max_tab_label_bytes + 16]u8 = undefined;
            const label = std.fmt.bufPrint(&tab_buffer, " {d}:{s} ", .{
                index + 1,
                tab.labelSlice(),
            }) catch " tab ";
            const remaining = input.area.x + input.area.w -| x;
            if (remaining == 0) break;
            const width = @min(ui.measure(label), remaining);
            const rect: ui.Rect = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
            const action: widget.Action = .{ .select_tab = tab.location.tab_id };
            context.hits.add(rect, action);
            const active = index == collection.active_index;
            const style: ui.Style = if (active)
                .{
                    .fg = context.palette.surface_dim,
                    .bg = context.palette.accent,
                    .flags = .{ .bold = true },
                }
            else if (context.isHovered(action))
                .{
                    .fg = context.palette.text,
                    .bg = context.palette.surface0,
                    .flags = .{ .underline = .single },
                }
            else
                barStyle(context);
            _ = context.buffer.writeTruncated(rect, x, input.area.y, label, width, style);
            x += width;
        }
    } else if (input.model.location) |location| {
        var tab_buffer: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&tab_buffer, " tab {d} ", .{
            schema.id.raw(location.tab_id),
        }) catch " tab ";
        const width = @min(ui.measure(label), input.area.w);
        const x = input.area.x + input.area.w - width;
        const rect: ui.Rect = .{ .x = x, .y = input.area.y, .w = width, .h = 1 };
        _ = context.buffer.writeTruncated(rect, x, input.area.y, label, width, .{
            .fg = context.palette.surface_dim,
            .bg = context.palette.accent,
            .flags = .{ .bold = true },
        });
    }
}

pub fn barStyle(context: *const widget.Context) ui.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

fn decimalDigits(value: usize) u16 {
    var remaining = value;
    var digits: u16 = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn displayWidth(label: []const u8, index: usize, available: u16) u16 {
    return @min(ui.measure(label) + decimalDigits(index + 1) + 3, available);
}
