const core = @import("telar-core");

/// Gives tabs a minimum readable label before sharing space between other slots.
/// Example: `const regions = calculate(area, .{ 24, 0, 40 }, 2);`
pub fn calculate(area: core.Rect, desired: [3]u16, tabs_index: usize) [3]core.Rect {
    var widths: [3]u16 = @splat(0);
    widths[tabs_index] = @min(desired[tabs_index], @min(area.w, 16));
    var remaining = area.w - widths[tabs_index];
    const first = if (tabs_index == 0) @as(usize, 1) else 0;
    const second = if (tabs_index == 2) @as(usize, 1) else 2;
    const custom_total = @as(u32, desired[first]) + desired[second];
    if (custom_total <= remaining) {
        widths[first] = desired[first];
        widths[second] = desired[second];
        remaining -= @intCast(custom_total);
    } else {
        widths[first] = @min(desired[first], remaining / 2);
        widths[second] = @min(desired[second], remaining / 2);
        remaining -= widths[first] + widths[second];
        for ([_]usize{ first, second }) |index| {
            const extra = @min(desired[index] - widths[index], remaining);
            widths[index] += extra;
            remaining -= extra;
        }
    }

    widths[tabs_index] += @min(desired[tabs_index] - widths[tabs_index], remaining);
    const right_x = area.x + area.w - widths[2];
    const center_x = @min(@max(area.x + (area.w - widths[1]) / 2, area.x + widths[0]), right_x - widths[1]);
    return .{
        .{ .x = area.x, .y = area.y, .w = widths[0], .h = area.h },
        .{ .x = center_x, .y = area.y, .w = widths[1], .h = area.h },
        .{ .x = right_x, .y = area.y, .w = widths[2], .h = area.h },
    };
}
