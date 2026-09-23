//! Encodes pane-relative SGR mouse reports, including exact host pixels.

const data = @import("model");
const mouse_protocol = @import("../../input/mouse_protocol.zig");
const core = @import("telar-core");
const std = @import("std");
const PixelProjection = @import("../../input/PixelProjection.zig");

/// Projects host pixels into pane coordinates before encoding the report.
/// Example: `const bytes = try pane_mouse_inputs.encodeReport(&buffer, report);`
pub fn encodeReport(buffer: []u8, report: data.ReportEffect) ![]const u8 {
    const command = report.command;
    const plan = report.plan;
    const exact_x: ?u32 = if (plan.protocol.pixels and command.exterior_pixels) exact: {
        const origin = @as(u32, plan.content.x) * command.cell_width_px;
        std.debug.assert(command.event.raw_x >= origin);
        break :exact command.event.raw_x - origin;
    } else null;
    const exact_y: ?u32 = if (plan.protocol.pixels and command.exterior_pixels) exact: {
        const origin = @as(u32, plan.content.y) * command.cell_height_px;
        std.debug.assert(command.event.raw_y >= origin);
        break :exact command.event.raw_y - origin;
    } else null;

    const pixels: ?PixelProjection = if (plan.protocol.pixels) .{
        .cell = .{ .width = command.cell_width_px, .height = command.cell_height_px },
        .exact = if (exact_x != null and exact_y != null) .{ .x = exact_x.?, .y = exact_y.? } else null,
    } else null;

    return mouse_protocol.encodeSgr(buffer, .{
        .event = command.event,
        .pane_position = .{
            .x = command.event.x - plan.content.x,
            .y = command.event.y - plan.content.y,
        },
        .pixels = pixels,
    });
}

test "pane mouse reports preserve exact host pixels relative to pane content" {
    var buffer: [64]u8 = undefined;
    const report: data.ReportEffect = .{
        .plan = .{
            .pane_id = @enumFromInt(1),
            .content = .{ .x = 2, .y = 3, .w = 10, .h = 5 },
            .protocol = .{ .tracking = .any, .sgr = true, .pixels = true },
            .alternate_scroll = false,
            .at_bottom = true,
        },
        .command = .{
            .event = .{
                .x = 2,
                .y = 3,
                .raw_x = 27,
                .raw_y = 69,
                .kind = .press,
            },
            .exterior_pixels = true,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    };

    try std.testing.expectEqualStrings("\x1b[<0;8;10M", try encodeReport(&buffer, report));
}

test "pane mouse pixel reports use cell centers without exact host pixels" {
    var buffer: [64]u8 = undefined;
    const report: data.ReportEffect = .{
        .plan = .{
            .pane_id = @enumFromInt(1),
            .content = .{ .x = 2, .y = 3, .w = 10, .h = 5 },
            .protocol = .{ .tracking = .any, .sgr = true, .pixels = true },
            .alternate_scroll = false,
            .at_bottom = true,
        },
        .command = .{
            .event = .{ .x = 3, .y = 4, .kind = .press },
            .exterior_pixels = false,
            .cell_width_px = 10,
            .cell_height_px = 20,
        },
    };

    try std.testing.expectEqualStrings("\x1b[<0;16;31M", try encodeReport(&buffer, report));
}
