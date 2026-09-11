const RectType = @import("telar-core").Rect;
const Widths = @import("Widths.zig");
const Regions = @This();

items: [3]RectType,

pub fn calculate(area: RectType, input: Widths) Regions {
    var widths: [3]u16 = @splat(0);
    const tabs_index: usize = input.tabs_index;
    const tab_minimum = @min(input.desired[tabs_index], @min(area.w, 16));
    widths[tabs_index] = tab_minimum;
    var remaining = area.w - tab_minimum;

    var custom_indices: [2]usize = undefined;
    var custom_count: usize = 0;
    for (0..3) |index| {
        if (index == tabs_index) {
            continue;
        }

        custom_indices[custom_count] = index;
        custom_count += 1;
    }

    const first = custom_indices[0];
    const second = custom_indices[1];
    const custom_total = @as(u32, input.desired[first]) + input.desired[second];
    if (custom_total <= remaining) {
        widths[first] = input.desired[first];
        widths[second] = input.desired[second];
        remaining -= @intCast(custom_total);
    } else {
        const share = remaining / 2;
        widths[first] = @min(input.desired[first], share);
        widths[second] = @min(input.desired[second], share);
        var unassigned = remaining - widths[first] - widths[second];
        const first_extra = @min(input.desired[first] - widths[first], unassigned);
        widths[first] += first_extra;
        unassigned -= first_extra;
        const second_extra = @min(input.desired[second] - widths[second], unassigned);
        widths[second] += second_extra;
        remaining = unassigned - second_extra;
    }

    const tab_extra = @min(input.desired[tabs_index] - tab_minimum, remaining);
    widths[tabs_index] += tab_extra;

    const left: RectType = .{ .x = area.x, .y = area.y, .w = widths[0], .h = area.h };
    const right: RectType = .{
        .x = area.x + area.w - widths[2],
        .y = area.y,
        .w = widths[2],
        .h = area.h,
    };
    const gap_start = left.x + left.w;
    const gap_end = right.x;
    const centered = area.x + (area.w - widths[1]) / 2;
    const center_x = @min(@max(centered, gap_start), gap_end - widths[1]);
    const center: RectType = .{ .x = center_x, .y = area.y, .w = widths[1], .h = area.h };

    return .{ .items = .{ left, center, right } };
}
