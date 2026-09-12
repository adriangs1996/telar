//! Wires pane mouse policy to viewport and pane-input effects.

const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const ApplicationInputPaneMouseCommand = @import("../../application/input/pane_mouse.zig").Command;
const ApplicationInputPaneMouseOutcome = @import("../../application/input/pane_mouse.zig").Outcome;
const PaneMouseInputsContext = @import("PaneMouseInputsContext.zig");
const PaneMouseHandlerType = @import("../../application/input/PaneMouseHandler.zig");
const ResolvedType = @import("../../application/input/Resolved.zig");
const EffectType = @import("../../application/input/pane_mouse.zig").Effect;
const copy_modes = @import("copy_modes.zig");
const monotonic_module = @import("../../resources/clock.zig").monotonic;
const pane_viewports = @import("../panes/pane_viewports.zig");
const std = @import("std");
const pane_inputs = @import("pane_inputs.zig");
const ReportEffectType = @import("../../application/input/ReportEffect.zig");
const PixelProjectionType = @import("../../input/PixelProjection.zig");
const encodeSgr_module = @import("../../input/mouse_protocol.zig").encodeSgr;

/// Resolves a pointer event or focused scroll without exposing pane storage
/// or child mouse modes to the caller.
///
/// ```zig
/// _ = try apply(client, model, command);
/// ```
pub fn apply(client: *Client, model: *MultiplexerModel, command: ApplicationInputPaneMouseCommand) !ApplicationInputPaneMouseOutcome {
    var context: PaneMouseInputsContext = .{
        .client = client,
        .model = model,
        .area = client.geometry().area,
    };
    var use_case: PaneMouseHandlerType = .{
        .plans = .{
            .context = &context,
            .resolve = resolve,
        },
        .effects = .{
            .context = &context,
            .apply = applyEffect,
        },
    };

    return use_case.execute(command);
}

fn resolve(raw_context: *anyopaque, command: ApplicationInputPaneMouseCommand) ?ResolvedType {
    const context: *PaneMouseInputsContext = @ptrCast(@alignCast(raw_context));

    return switch (command) {
        .pointer => |pointer| .{
            .plan = context.model.planPaneMouse(pointer.event, context.area) orelse return null,
            .pointer = pointer,
        },
        .focused_scroll => |direction| focused: {
            const plan = context.model.planFocusedPaneMouse(context.area) orelse return null;
            const host_size = context.client.model.hostSize();

            break :focused .{
                .plan = plan,
                .pointer = .{
                    .event = .{
                        .x = plan.content.x,
                        .y = plan.content.y,
                        .kind = if (direction == .up) .scroll_up else .scroll_down,
                        .button = if (direction == .up) 64 else 65,
                    },
                    .exterior_pixels = false,
                    .cell_width_px = host_size.cell_width_px,
                    .cell_height_px = host_size.cell_height_px,
                },
            };
        },
    };
}

fn applyEffect(raw_context: *anyopaque, effect: EffectType) !void {
    const context: *PaneMouseInputsContext = @ptrCast(@alignCast(raw_context));

    switch (effect) {
        .selection => |selection| {
            _ = copy_modes.beginPointer(context.client, .{
                .pane_id = selection.plan.pane_id,
                .position = .{
                    .x = selection.command.event.x - selection.plan.content.x,
                    .y = selection.command.event.y - selection.plan.content.y,
                },
                .now_ns = monotonic_module(context.client.io),
            });
        },
        .viewport => |scroll| {
            var use_case = pane_viewports.handler(context.client);

            _ = try use_case.execute(.{
                .pane_id = scroll.pane_id,
                .target = .{ .relative = scroll.delta },
            });
        },
        .alternate_scroll => |scroll| {
            std.debug.assert(scroll.delta != 0);
            const bytes = if (scroll.delta < 0) "\x1b[A" else "\x1b[B";
            for (0..@abs(scroll.delta)) |_| {
                _ = try pane_inputs.send(context.client, .{
                    .target = .{ .pane = scroll.pane_id },
                    .source = .mouse,
                    .payload = .{ .bytes = bytes },
                });
            }
        },
        .report => |report| {
            var encoded: [64]u8 = undefined;
            const bytes = try encodeReport(&encoded, report);

            _ = try pane_inputs.send(context.client, .{
                .target = .{ .pane = report.plan.pane_id },
                .source = .mouse,
                .payload = .{ .bytes = bytes },
            });
        },
    }
}

fn encodeReport(buffer: []u8, report: ReportEffectType) ![]const u8 {
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

    const pixels: ?PixelProjectionType = if (plan.protocol.pixels) .{
        .cell = .{ .width = command.cell_width_px, .height = command.cell_height_px },
        .exact = if (exact_x != null and exact_y != null) .{ .x = exact_x.?, .y = exact_y.? } else null,
    } else null;

    return encodeSgr_module(buffer, .{
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
    const report: ReportEffectType = .{
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
    const report: ReportEffectType = .{
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
