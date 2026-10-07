//! Disposable pane layout owned by the client.

const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const SplitGeometry = @import("SplitGeometry.zig");
const std = @import("std");

pub const max_nodes = core.max_panes_per_tab * 2 - 1;
pub const NodeIndex = u8;
const index_capacity = core.max_panes_per_tab * 2;
pub const ViewIndex = core.GenericSlotIndex(index_capacity);

pub const default_split_ratio: u16 = core.client_layout_ratio_scale / 2;

pub const resize_step: u16 = core.client_layout_ratio_scale / 20;

pub const Axis = @import("LayoutAxis.zig").LayoutAxis;

pub const Direction = @import("LayoutDirection.zig").LayoutDirection;

pub fn splitArea(geometry: SplitGeometry) [2]cellgrid.Rect {
    std.debug.assert(geometry.ratio <= core.client_layout_ratio_scale);

    return switch (geometry.axis) {
        .horizontal => horizontal: {
            const gutter: u16 = if (geometry.area.w >= geometry.gap + 2) geometry.gap else 0;
            const usable = geometry.area.w - gutter;
            const first_width: u16 = @intCast(
                @as(u32, usable) * geometry.ratio / core.client_layout_ratio_scale,
            );
            break :horizontal .{
                .{
                    .x = geometry.area.x,
                    .y = geometry.area.y,
                    .w = first_width,
                    .h = geometry.area.h,
                },
                .{
                    .x = geometry.area.x + first_width + gutter,
                    .y = geometry.area.y,
                    .w = usable - first_width,
                    .h = geometry.area.h,
                },
            };
        },
        .vertical => vertical: {
            const gutter: u16 = if (geometry.area.h >= geometry.gap + 4) geometry.gap else 0;
            const usable = geometry.area.h - gutter;
            const first_height: u16 = @intCast(
                @as(u32, usable) * geometry.ratio / core.client_layout_ratio_scale,
            );
            break :vertical .{
                .{
                    .x = geometry.area.x,
                    .y = geometry.area.y,
                    .w = geometry.area.w,
                    .h = first_height,
                },
                .{
                    .x = geometry.area.x,
                    .y = geometry.area.y + first_height + gutter,
                    .w = geometry.area.w,
                    .h = usable - first_height,
                },
            };
        },
    };
}

/// The ratio that gives the first of `remaining` panes an equal share of a
/// region, bounded by the ratios a client layout may carry.
pub fn equalShareRatio(remaining: usize) u16 {
    const share: u16 = @intCast(core.client_layout_ratio_scale / remaining);
    return std.math.clamp(
        share,
        core.min_client_layout_ratio,
        core.max_client_layout_ratio,
    );
}

pub fn extent(area: cellgrid.Rect, axis: Axis) u16 {
    return switch (axis) {
        .horizontal => area.w,
        .vertical => area.h,
    };
}

pub fn center(origin: u16, length: u16) u32 {
    return @as(u32, origin) * 2 + length;
}

pub fn distance(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}
